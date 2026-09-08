import CoreLocation

enum LocationAuthorization { case notDetermined, denied, authorized }

protocol LocationProviding: AnyObject {
    var coordinate: (latitude: Double, longitude: Double)? { get }
    var authorization: LocationAuthorization { get }
    var isApproximate: Bool { get }
    var onChange: (() -> Void)? { get set }
    func requestWhenInUse()
}

final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private let timeZone: TimeZone
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
           let lon = defaults.object(forKey: "redlight.location.lon") as? Double {
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
        manager.requestWhenInUseAuthorization()
        startUpdatingIfAuthorized()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        accept(loc)
        m.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        startUpdatingIfAuthorized()
        onChange?()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.denied.rawValue {
            m.stopUpdatingLocation()
            onChange?()
            return
        }
        // `kCLErrorLocationUnknown` is routine on a Mac without GPS. Keep the time-zone
        // fallback in place and leave updates running so a later Wi-Fi/IP fix can land.
        ensureFallbackCoordinate()
    }

    private func startUpdatingIfAuthorized() {
        guard authorization == .authorized else { return }
        if let existing = manager.location {
            accept(existing)
        }
        manager.startUpdatingLocation()
    }

    private func accept(_ loc: CLLocation) {
        coordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
        isApproximate = false
        defaults.set(loc.coordinate.latitude, forKey: "redlight.location.lat")
        defaults.set(loc.coordinate.longitude, forKey: "redlight.location.lon")
        onChange?()
    }

    private func ensureFallbackCoordinate() {
        guard coordinate == nil else { return }
        coordinate = ApproximateLocation.from(timeZone)
        isApproximate = true
        onChange?()
    }
}
