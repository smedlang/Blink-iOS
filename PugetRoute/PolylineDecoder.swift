import CoreLocation

/// Decodes Google's encoded polyline format (precision 5), which is what OTP
/// returns in `legGeometry.points`.
///
/// Spec: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
enum PolylineDecoder {

    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        let chars = Array(encoded.unicodeScalars)
        var index = 0
        var lat = 0, lon = 0

        while index < chars.count {
            let dLat = readVarint(chars: chars, index: &index)
            let dLon = readVarint(chars: chars, index: &index)
            lat += dLat
            lon += dLon
            coords.append(CLLocationCoordinate2D(
                latitude:  Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }
        return coords
    }

    private static func readVarint(chars: [Unicode.Scalar], index: inout Int) -> Int {
        var result = 0
        var shift = 0
        while true {
            guard index < chars.count else { return 0 }
            let b = Int(chars[index].value) - 63
            index += 1
            result |= (b & 0x1f) << shift
            shift += 5
            if b < 0x20 { break }
        }
        // zig-zag decode
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
