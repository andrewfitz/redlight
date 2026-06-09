import CoreLocation

enum LocationAuthorization { case notDetermined, denied, authorized }

protocol LocationProviding: AnyObject {
    var coordinate: (latitude: Double, longitude: Double)? { get }
    var authorization: LocationAuthorization { get }
    var onChange: (() -> Void)? { get set }
    func requestWhenInUse()
}

final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    private(set) var coordinate: (latitude: Double, longitude: Double)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let lat = defaults.object(forKey: "redlight.location.lat") as? Double,
           let lon = defaults.object(forKey: "redlight.location.lon") as? Double {
            coordinate = (lat, lon)
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
        if authorization == .authorized { manager.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        coordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
        defaults.set(loc.coordinate.latitude, forKey: "redlight.location.lat")
        defaults.set(loc.coordinate.longitude, forKey: "redlight.location.lon")
        onChange?()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if authorization == .authorized { m.requestLocation() }
        onChange?()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
