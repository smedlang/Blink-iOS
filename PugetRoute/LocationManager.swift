import Foundation
import CoreLocation

/// Wrapper around CLLocationManager for both one-shot lookups (start-of-trip
/// "Current location" pin) and continuous navigation-mode tracking.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var lastLocation: CLLocation?
    @Published var heading: CLHeading?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True while `startLiveUpdates()` is active (i.e. the user is in
    /// navigation mode and we want fresh fixes a few times a second).
    @Published private(set) var isTracking = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func requestOneShotLocation() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestLocation()
    }

    /// Request a fresh fix and await it. Returns the new `CLLocation`
    /// when CoreLocation responds, or the most-recent cached value if
    /// CoreLocation hangs past `timeout` (rare — usually the delegate
    /// resolves within ~1 s).
    ///
    /// `planTrip()` calls this so trips planned after the user has
    /// moved start from where they are now, not the coord captured at
    /// app launch.
    func freshOneShot(timeout: TimeInterval = 5) async -> CLLocation? {
        // If a previous waiter is still in flight, resolve it now with
        // the current cached value — we never want two outstanding
        // continuations contending for the same delegate callback.
        if let prev = oneShotContinuation {
            oneShotContinuation = nil
            prev.resume(returning: lastLocation)
        }

        oneShotToken &+= 1
        let token = oneShotToken
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            oneShotContinuation = cont
            manager.requestLocation()

            // Safety net for the unusual case where CoreLocation neither
            // delivers a fix nor errors. Tokened so a later call's
            // timeout can't accidentally pop this one's continuation.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self,
                      self.oneShotToken == token,
                      let pending = self.oneShotContinuation else { return }
                self.oneShotContinuation = nil
                pending.resume(returning: self.lastLocation)
            }
        }
    }

    private var oneShotContinuation: CheckedContinuation<CLLocation?, Never>?
    private var oneShotToken: Int = 0

    /// Begin continuous high-accuracy updates for navigation.
    ///
    /// Battery tuning
    /// --------------
    /// `kCLLocationAccuracyBestForNavigation` is too aggressive — it forces
    /// the GPS chip into a full-power mode meant for cars at 60 mph, and on
    /// a phone in a bike-mount it eats the battery while delivering accuracy
    /// well beyond what a 5 m distanceFilter could ever surface. Stepping
    /// down to `kCLLocationAccuracyNearestTenMeters` gets us 10–15 m fixes
    /// (more than enough to snap to a polyline at the tens-of-meters scale)
    /// while letting the chip duty-cycle.
    ///
    /// `pausesLocationUpdatesAutomatically = true` lets iOS pause updates
    /// when CoreLocation infers the user has stopped — sitting at a long
    /// red light, waiting at a bus stop, etc. The OS resumes them as soon
    /// as motion resumes, with no work from us.
    ///
    /// `allowsBackgroundLocationUpdates` is intentionally left off — we
    /// only need fixes while the user is looking at the nav screen.
    func startLiveUpdates() {
        guard !isTracking else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5          // meters
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 5       // degrees — match camera throttle
            manager.startUpdatingHeading()
        }
        isTracking = true
    }

    /// Stop continuous updates when navigation ends.
    func stopLiveUpdates() {
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        isTracking = false
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            if let cont = self.oneShotContinuation {
                self.oneShotContinuation = nil
                cont.resume(returning: loc)
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.heading = newHeading }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.oneShotContinuation {
                self.oneShotContinuation = nil
                cont.resume(returning: self.lastLocation)
            }
        }
        // Silent for MVP; surface to UI later.
        print("Location error: \(error)")
    }
}
