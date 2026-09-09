import CoreLocation

enum LocationAuthorization { case notDetermined, denied, authorized }

protocol LocationProviding: AnyObject {
    var coordinate: (latitude: Double, longitude: Double)? { get }
    var authorization: LocationAuthorization { get }
    var isApproximate: Bool { get }
    var onChange: (() -> Void)? { get set }
    func requestWhenInUse()
    /// Stop any in-flight fix. Called when Adaptive turns off so the location hardware is
    /// never left running for a feature nobody is using.
    func cancelRequest()
}

final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private let timeZone: TimeZone
    /// True between `requestWhenInUse()` and either a fix or `cancelRequest()`. Authorization
    /// callbacks arrive asynchronously (and at launch); without this they would start the
    /// hardware even when Adaptive is off.
    private var wantsFix = false
    var onChange: (() -> Void)?
    private(set) var coordinate: (latitude: Double, longitude: Double)?
    private(set) var isApproximate = false

    init(defaults: UserDefaults = .standard, timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.timeZone = timeZone
        super.init()
        manager.delegate = self
        // Desktop Macs (Studio on ethernet, Wi-Fi off) often cannot satisfy kilometer
        // accuracy. Three-kilometer / city-level is enough for solar elevation and is
        // the accuracy Core Location can actually produce without a Wi-Fi scan.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        if let lat = defaults.object(forKey: "redlight.location.lat") as? Double,
           let lon = defaults.object(forKey: "redlight.location.lon") as? Double,
           Self.isValid(latitude: lat, longitude: lon) {
            coordinate = (lat, lon)
        } else {
            coordinate = ApproximateLocation.from(timeZone)
            isApproximate = true
        }
    }

    var authorization: LocationAuthorization {
        // Treat every granted variant (authorized / authorizedAlways /
        // authorizedWhenInUse) the same without naming platform-specific cases.
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .authorized
        }
    }

    func requestWhenInUse() {
        wantsFix = true
        switch manager.authorizationStatus {
        case .notDetermined:
            // Updates start from the authorization callback once the user answers.
            manager.requestWhenInUseAuthorization()
        default:
            startUpdatingIfWanted()
        }
    }

    func cancelRequest() {
        wantsFix = false
        manager.stopUpdatingLocation()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        // A negative horizontal accuracy is Core Location's "invalid fix" marker.
        guard let loc = locs.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        accept(loc)
        wantsFix = false
        m.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        startUpdatingIfWanted()
        onChange?()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.denied.rawValue {
            wantsFix = false
            m.stopUpdatingLocation()
            onChange?()
            return
        }
        // `kCLErrorLocationUnknown` is routine on a Mac without GPS. Keep the time-zone
        // fallback in place and leave updates running so a later Wi-Fi/IP fix can land.
        ensureFallbackCoordinate()
    }

    private func startUpdatingIfWanted() {
        guard wantsFix, authorization == .authorized else { return }
        // The system's last known fix is usually recent and costs nothing. Use it right
        // away; only ask the hardware when it is missing or old enough that the Mac may
        // have moved (solar elevation only needs city-level accuracy).
        if let existing = manager.location, existing.horizontalAccuracy >= 0 {
            accept(existing)
            if -existing.timestamp.timeIntervalSinceNow < 15 * 60 {
                wantsFix = false
                return
            }
        }
        manager.startUpdatingLocation()
    }

    private func accept(_ loc: CLLocation) {
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        guard Self.isValid(latitude: lat, longitude: lon) else { return }
        // Solar elevation is insensitive to sub-kilometer moves; skip the redundant
        // re-apply (and the UserDefaults write) when nothing meaningful changed.
        if !isApproximate, let current = coordinate,
           abs(current.latitude - lat) < 0.01, abs(current.longitude - lon) < 0.01 {
            return
        }
        coordinate = (lat, lon)
        isApproximate = false
        defaults.set(lat, forKey: "redlight.location.lat")
        defaults.set(lon, forKey: "redlight.location.lon")
        onChange?()
    }

    private func ensureFallbackCoordinate() {
        guard coordinate == nil else { return }
        coordinate = ApproximateLocation.from(timeZone)
        isApproximate = true
        onChange?()
    }

    private static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}
