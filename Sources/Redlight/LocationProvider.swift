import CoreLocation
import Foundation

enum LocationAuthorization { case notDetermined, denied, authorized }

@MainActor
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

/// Core Location wrapper with a time-zone fallback so Adaptive always has *some* coordinate.
///
/// Threading: `CLLocationManager` delivers delegate callbacks on the run loop of the thread
/// that created it, and this object is created on the main actor, so the `nonisolated`
/// delegate entry points can hop straight back onto `MainActor` with `assumeIsolated`.
/// That keeps the whole class main-actor-isolated like the `DisplayManager` that owns it.
@MainActor
final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private var timeZone: TimeZone
    /// True between `requestWhenInUse()` and either a fix or `cancelRequest()`. Authorization
    /// callbacks arrive asynchronously (and at launch); without this they would start the
    /// hardware even when Adaptive is off.
    private var wantsFix = false
    // nonisolated(unsafe): set once in init on the main actor; read in deinit for cleanup.
    nonisolated(unsafe) private var timeZoneObserver: NSObjectProtocol?
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
        // A laptop that was denied location but flies to another time zone should still
        // move its fallback city. Only matters while the coordinate is the fallback.
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemTimeZoneChanged() }
        }
    }

    deinit {
        if let timeZoneObserver { NotificationCenter.default.removeObserver(timeZoneObserver) }
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
            // The fix is requested from the authorization callback once the user answers.
            manager.requestWhenInUseAuthorization()
        default:
            requestFixIfWanted()
        }
    }

    func cancelRequest() {
        wantsFix = false
        manager.stopUpdatingLocation()   // also cancels a pending requestLocation()
    }

    // MARK: - CLLocationManagerDelegate (delivered on the creating thread: main)

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        MainActor.assumeIsolated {
            // A negative horizontal accuracy is Core Location's "invalid fix" marker.
            guard let loc = locs.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
            wantsFix = false
            accept(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated {
            if authorization == .authorized {
                requestFixIfWanted()
            } else {
                manager.stopUpdatingLocation()
            }
            onChange?()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        let denied = nsError.domain == kCLErrorDomain && nsError.code == CLError.denied.rawValue
        MainActor.assumeIsolated {
            if denied {
                wantsFix = false
                manager.stopUpdatingLocation()
                onChange?()
            }
            // `kCLErrorLocationUnknown` is routine on a Mac without GPS: the one-shot
            // request has timed out. The time-zone fallback stays in place and
            // `DisplayManager` asks again in a minute, so nothing needs to keep running.
        }
    }

    // MARK: - Private

    private func requestFixIfWanted() {
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
        // One-shot: delivers a single fix or a single error (after Core Location's own
        // ~10 s timeout) and stops itself, so the "location in use" arrow never sits in
        // the menu bar for the life of Adaptive on a Mac that can't get a fix.
        manager.requestLocation()
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

    private func systemTimeZoneChanged() {
        timeZone = .current
        guard isApproximate else { return }
        let fresh = ApproximateLocation.from(timeZone)
        if let current = coordinate, current == fresh { return }
        coordinate = fresh
        onChange?()
    }

    private static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}
