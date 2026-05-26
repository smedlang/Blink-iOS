import SwiftUI
import MapKit

/// UIKit-backed MapView that renders an itinerary's legs as colored polylines.
/// Uses MKMapView via UIViewRepresentable because SwiftUI's `Map` view doesn't
/// yet expose per-overlay styling in a way that plays well with multiple legs.
///
/// **Bike-rack overlay.** When `bikeRacks` is non-empty, each entry renders
/// as a small grey-blue bike glyph on top of the route line. The caller
/// (typically `ContentView`) is responsible for fetching the racks via
/// `BikeRackService.racksForBikeLegEndpoints` once the itinerary is
/// selected and passing them in. Racks are presentational only — they
/// don't affect routing, ordering, or any other downstream logic.
struct ItineraryMapView: UIViewRepresentable {
    let itinerary: Itinerary?
    var bikeRacks: [BikeRack] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        // Default region: Seattle
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
        ), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

        guard let it = itinerary else { return }

        var allPoints: [CLLocationCoordinate2D] = []
        for leg in it.legs {
            let pts = PolylineDecoder.decode(leg.legGeometry.points)
            guard pts.count >= 2 else { continue }
            allPoints.append(contentsOf: pts)

            // Bike legs get split into per-step segments so the renderer can
            // color the on-infra portion green and the on-street portion blue.
            // Walk and transit legs render as a single overlay. Rental
            // (Lime) bike legs skip the infra split — a single Lime-tinted
            // line across the whole rental ride communicates "this is a
            // bikeshare segment" more clearly than the infra-coloring would.
            if leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" {
                if leg.isRental {
                    let line = LegPolyline(coordinates: pts, count: pts.count)
                    line.mode = leg.mode
                    line.isRental = true
                    map.addOverlay(line)
                } else {
                    let segments = bikeLegSegments(leg)
                    for seg in segments where seg.coords.count >= 2 {
                        let line = LegPolyline(coordinates: seg.coords, count: seg.coords.count)
                        line.mode = leg.mode
                        line.isOnBikeInfra = seg.onBikeInfra
                        map.addOverlay(line)
                    }
                }
            } else {
                let line = LegPolyline(coordinates: pts, count: pts.count)
                line.mode = leg.mode
                // Transit legs carry their route's brand color into
                // the renderer. Non-transit walk legs leave it nil and
                // the renderer picks .systemGray with a dashed pattern.
                if leg.isTransit {
                    line.brandStrokeColor = leg.transitBrand.uiColor
                }
                map.addOverlay(line)
            }
        }

        // Start + end pins
        if let first = it.legs.first, let last = it.legs.last {
            let start = MKPointAnnotation()
            start.coordinate = first.from.coordinate
            start.title = "Start"
            map.addAnnotation(start)

            let end = MKPointAnnotation()
            end.coordinate = last.to.coordinate
            end.title = "End"
            map.addAnnotation(end)
        }

        // Mark every transit stop along the route with a small dot —
        // boarding (orange), alighting (red), and every intermediate stop
        // the bus makes in between (small unfilled dot). The polyline alone
        // makes it hard to tell at a glance where the bus actually stops,
        // and the intermediate dots help the user pick which stop to get
        // off at when there's a closer-to-destination option.
        //
        // Dedupe by coordinate (5-decimal precision ≈ 1 m) so a transfer
        // where one leg's "to" and the next leg's "from" share a stop
        // doesn't double up, and so an intermediate stop that happens to
        // coincide with a boarding/alighting stop on a different leg
        // defers to the louder dot.
        var seenStops = Set<String>()
        // Boarding/alighting first so they win the dedup over intermediate
        // dots at the same coordinate. Dedup keys use the stop's *actual*
        // lat/lon (so a transfer stop shared by adjacent legs collapses
        // to one annotation), but the annotation's rendered coordinate is
        // snapped onto the leg's polyline so dots sit on the colored line
        // instead of floating at the curb-side stop a few meters off.
        for leg in it.legs where leg.isTransit {
            let legPts = PolylineDecoder.decode(leg.legGeometry.points)
            let brand = leg.transitBrand.uiColor
            for endpoint in [(leg.from.coordinate, leg.from.name, TransitStopAnnotation.Kind.boarding),
                             (leg.to.coordinate,   leg.to.name,   TransitStopAnnotation.Kind.alighting)] {
                let key = String(format: "%.5f,%.5f", endpoint.0.latitude, endpoint.0.longitude)
                if seenStops.insert(key).inserted {
                    let stop = TransitStopAnnotation()
                    stop.coordinate = Self.snapToPolyline(endpoint.0, polyline: legPts)
                    stop.title = endpoint.1
                    stop.kind = endpoint.2
                    stop.brandColor = brand
                    map.addAnnotation(stop)
                }
            }
        }
        // Intermediate stops second.
        for leg in it.legs where leg.isTransit {
            let legPts = PolylineDecoder.decode(leg.legGeometry.points)
            let brand = leg.transitBrand.uiColor
            for inter in leg.intermediateStops ?? [] {
                let key = String(format: "%.5f,%.5f", inter.lat, inter.lon)
                if seenStops.insert(key).inserted {
                    let stop = TransitStopAnnotation()
                    stop.coordinate = Self.snapToPolyline(inter.coordinate, polyline: legPts)
                    stop.title = inter.name
                    stop.kind = .intermediate
                    stop.brandColor = brand
                    map.addAnnotation(stop)
                }
            }
        }

        // Bike-rack annotations near each bike-leg endpoint. Rendered
        // after stops so the dequeue path stays clean (each kind has
        // its own reuse identifier in the coordinator's viewFor).
        // Deduped client-side by `BikeRack.id` already; this loop just
        // attaches the annotations.
        for rack in bikeRacks {
            let ann = BikeRackAnnotation()
            ann.coordinate = rack.coordinate
            ann.title = rack.name?.isEmpty == false ? rack.name : "Bike parking"
            let summary = rack.summary
            if !summary.isEmpty {
                ann.subtitle = summary
            }
            ann.rack = rack
            map.addAnnotation(ann)
        }

        if !allPoints.isEmpty {
            let rect = polylineRect(points: allPoints)
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 280, right: 40),
                animated: true
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? LegPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: line)
            switch line.mode {
            case "BICYCLE", "BICYCLE_RENT":
                if line.isRental {
                    // Lime brand-ish green for rental rides. Bright enough
                    // to read as "Lime" against the map background. Color
                    // value lives in Palette so the Lime toggle pill in
                    // ContentView's search bar stays in sync.
                    r.strokeColor = Palette.limeUI
                    r.lineWidth = 5
                } else {
                    // Pine green (#00875A) when on a known bike facility
                    // (trail / cycletrack / protected lane), blue when on
                    // regular streets. Per-leg splitting happens in
                    // updateUIView via bikeLegSegments(). #00875A is
                    // dark/saturated enough that it doesn't collide with
                    // Sound Transit Link 1 (#3DAE2B, brighter green) or
                    // WSF (#006434, even darker). Color value lives in
                    // Palette — NavigationView.swift's renderer uses the
                    // same constant.
                    r.strokeColor = line.isOnBikeInfra ? Palette.bikeInfraUI : .systemBlue
                    r.lineWidth = 5
                }
            case "WALK":
                r.strokeColor = .systemGray
                r.lineWidth = 4
                r.lineDashPattern = [2, 6]
            default: // transit
                // Per-route brand color when known (Sound Transit Link,
                // Sounder, STRIDE, T Line); falls back to systemOrange
                // for unmapped operators. Brand color is computed at
                // overlay-add time in updateUIView so the renderer
                // doesn't need access to the original Leg.
                r.strokeColor = line.brandStrokeColor ?? .systemOrange
                r.lineWidth = 6
            }
            return r
        }

        // Render bus-stop dots as small colored circles. We use a
        // MKAnnotationView (not MKPinAnnotationView) so the dot can sit
        // flush with the polyline instead of dangling above it like a pin.
        //
        // Three sizes/styles so the visual hierarchy matches the importance
        // to the rider:
        //   .boarding    — 14px orange-filled circle (the get-on stop)
        //   .alighting   — 14px red-filled circle (the get-off stop)
        //   .intermediate — 8px white dot with orange ring (a stop the
        //                   bus passes through; legible at zoom but quiet
        //                   enough not to overpower the boarding dots)
        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let stop = annotation as? TransitStopAnnotation {
                return Self.makeStopAnnotationView(for: stop, on: map, reuseId: "transit-stop")
            }
            if let rack = annotation as? BikeRackAnnotation {
                return Self.makeBikeRackAnnotationView(for: rack, on: map)
            }
            return nil
        }

        /// Build the bus-stop annotation view for any of the three kinds.
        /// Static so the navigation-map coordinator can reuse the exact
        /// same rendering (its delegate type is different but the visual
        /// is identical).
        static func makeStopAnnotationView(
            for stop: TransitStopAnnotation,
            on map: MKMapView,
            reuseId: String
        ) -> MKAnnotationView {
            let isIntermediate = stop.kind == .intermediate
            // Intermediate stops use a separate reuse id so the dequeued
            // view always matches the size we want to render — mixing
            // sizes through one pool gave us 14px frames around 8px dots.
            let id = isIntermediate ? "\(reuseId)-mid" : reuseId
            let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: stop, reuseIdentifier: id)
            view.annotation = stop
            // Intermediate stops don't show a callout — there are too many
            // of them along a long bus leg, and the user already gets the
            // boarding/alighting names from the trip detail card.
            view.canShowCallout = !isIntermediate
            let size: CGFloat = isIntermediate ? 8 : 14
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.backgroundColor = .clear
            view.subviews.forEach { $0.removeFromSuperview() }

            // White-filled circle ringed in the route's brand color so each
            // stop visually belongs to its line (Link green ring on Link
            // stops, RapidRide red ring on RapidRide stops, etc.). The
            // boarding/alighting endpoints get a thicker ring (2pt) to
            // remain the most prominent dots on the line; intermediate
            // stops get a 1pt ring so they read as "the bus passes here"
            // without competing with the endpoints. Falls back to
            // systemOrange when no brand color is set (defensive — every
            // transit stop should have one once `brandColor` is plumbed).
            let dot = UIView(frame: view.bounds)
            dot.backgroundColor = .white
            dot.layer.cornerRadius = dot.bounds.width / 2
            dot.layer.borderColor = (stop.brandColor ?? .systemOrange).cgColor
            dot.layer.borderWidth = isIntermediate ? 1 : 2
            dot.isUserInteractionEnabled = false
            view.addSubview(dot)
            return view
        }

        /// Bike-rack annotation. Composed glyph showing a bike resting
        /// on top of a U-stand rack — visually answers "this is bike
        /// parking" without needing a label. No surrounding frame; a
        /// thin white halo behind both shapes keeps them legible on
        /// dark map tiles without painting a competing rectangle.
        ///
        /// The icon is rendered once into a static `UIImage` and
        /// reused across all annotations — the dequeue path just
        /// re-skins existing views with the cached image.
        ///
        /// Callout shows the rack's name (or "Bike parking" generic)
        /// plus a subtitle summary (capacity / type / covered / access
        /// — see BikeRack.summary).
        static func makeBikeRackAnnotationView(
            for rack: BikeRackAnnotation,
            on map: MKMapView
        ) -> MKAnnotationView {
            let id = "bike-rack"
            let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: rack, reuseIdentifier: id)
            view.annotation = rack
            view.canShowCallout = true
            view.image = bikeRackIcon
            return view
        }

        /// Pre-rendered icon for bike-rack annotations. Drawn once at
        /// module-load time into a UIImage. Doing it as a single image
        /// (rather than stacked subviews per annotation) keeps the
        /// dequeue cycle clean — image-based MKAnnotationViews recycle
        /// correctly without leaking previous annotations' subview
        /// hierarchies.
        ///
        /// Composition: a blue filled circle with a white "P"
        /// (parkingsign) centered inside. Standard cycling-map
        /// convention — Strava, Komoot, and most transportation
        /// agencies mark bike parking with a "P" badge. The "bike"
        /// reading is implicit from context (this is the bike-routing
        /// app and racks only appear on bike-leg endpoints). Thin
        /// white outer halo lifts the badge off the map tiles in
        /// both light and satellite modes without painting a
        /// competing rectangle.
        private static let bikeRackIcon: UIImage = renderBikeRackIcon(tint: .systemBlue)

        private static func renderBikeRackIcon(tint: UIColor) -> UIImage {
            // 22 pt outer (including the white halo), 20 pt inner blue
            // circle. Slightly larger than transit stops (14 pt) so the
            // "P" is legible — but the same compact, no-frame footprint.
            let outer: CGFloat = 22
            let circle: CGFloat = 20
            let size = CGSize(width: outer, height: outer)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                let cg = ctx.cgContext

                // White outer disk for contrast on map tiles. Draws
                // first so subsequent fills sit on top.
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: CGRect(origin: .zero, size: size))

                // Blue filled inner disk — the badge body.
                let inset = (outer - circle) / 2
                cg.setFillColor(tint.cgColor)
                cg.fillEllipse(in: CGRect(
                    x: inset, y: inset, width: circle, height: circle
                ))

                // White "P" centered. We use the bare `parkingsign`
                // symbol (not `.circle.fill`) since we already drew
                // the circle ourselves — this lets us pick the bg vs.
                // glyph colors independently, regardless of how SF
                // Symbols orders the layers in different iOS versions.
                let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .heavy)
                if let p = UIImage(systemName: "parkingsign", withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    let pRect = CGRect(
                        x: (outer - p.size.width) / 2,
                        y: (outer - p.size.height) / 2,
                        width: p.size.width,
                        height: p.size.height
                    )
                    p.draw(in: pRect)
                }
            }
        }
    }

    /// Returns the polyline vertex closest to `coord` in meters. Used to
    /// snap a stop's curb-side lat/lon onto the colored route line so the
    /// dots sit visually on the path. OTP polyline vertices are spaced
    /// roughly every 10–30 m along urban streets, so snapping to the
    /// nearest vertex (rather than the nearest point on a segment) is
    /// accurate enough for transit-stop annotations and far cheaper than
    /// the perpendicular-foot-of-segment math.
    static func snapToPolyline(_ coord: CLLocationCoordinate2D, polyline: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard let first = polyline.first else { return coord }
        let center = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var best = first
        var bestD = CLLocation(latitude: first.latitude, longitude: first.longitude).distance(from: center)
        for p in polyline.dropFirst() {
            let d = CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: center)
            if d < bestD { bestD = d; best = p }
        }
        return best
    }

    private func polylineRect(points: [CLLocationCoordinate2D]) -> MKMapRect {
        let mkPoints = points.map { MKMapPoint($0) }
        guard let first = mkPoints.first else { return .world }
        var rect = MKMapRect(origin: first, size: .init(width: 0, height: 0))
        for p in mkPoints.dropFirst() {
            rect = rect.union(MKMapRect(origin: p, size: .init(width: 0, height: 0)))
        }
        return rect
    }
}

/// Subclass so we can attach the mode tag and color the renderer.
/// `isOnBikeInfra` is meaningful only for bike-mode overlays — bike legs are
/// split into per-step sub-polylines (see `bikeLegSegments`) and each
/// segment gets its own LegPolyline with this flag set so the renderer can
/// pick green vs. blue without re-running the heuristic.
final class LegPolyline: MKPolyline {
    var mode: String = "WALK"
    var isOnBikeInfra: Bool = false
    /// True when this segment belongs to a Lime bikeshare rental leg.
    /// Overrides the bike-infra green/blue split with a single Lime-tinted
    /// color across the whole rental ride, so the user sees the rental
    /// portion as visually distinct from an own-bike leg on the same map.
    var isRental: Bool = false
    /// Brand color for transit legs, set per-overlay from the leg's
    /// route (see `Leg.transitBrand`). Nil for walk/bike legs and
    /// unused transit legs we haven't mapped — the renderer falls
    /// back to .systemOrange in that case.
    var brandStrokeColor: UIColor?
}

/// Annotation for transit stops along a route. Rendered as a small white
/// circle on top of the transit polyline, ringed in the operator's brand
/// color so each marker visually belongs to its line. Boarding/alighting
/// dots are larger with a thicker ring so they remain the most prominent
/// thing on the line; intermediate stops are smaller with a thinner ring.
final class TransitStopAnnotation: MKPointAnnotation {
    enum Kind {
        /// Where the user gets on this leg.
        case boarding
        /// Where the user gets off this leg.
        case alighting
        /// A stop the bus makes between boarding and alighting. Rendered
        /// smaller and thinner-ringed so the boarding/alighting dots
        /// remain the most prominent thing on the line.
        case intermediate
    }
    var kind: Kind = .boarding
    /// Brand color of the transit line this stop belongs to. The
    /// annotation view uses it as the ring color so a Link stop is
    /// outlined in Link green, a RapidRide stop in RapidRide red, etc.
    /// Falls back to `.systemOrange` when nil (shouldn't happen for
    /// transit stops, which always have a route brand).
    var brandColor: UIColor?
}
