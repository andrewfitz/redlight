import CoreLocation
import CoreFoundation
import Foundation

enum LocationAuthorization { case notDetermined, denied, authorized }

@MainActor
protocol LocationProviding: AnyObject {
    var coordinate: (latitude: Double, longitude: Double)? { get }
    var authorization: LocationAuthorization { get }
    var isApproximate: Bool { get }
    var onChange: (() -> Void)? { get set }
    /// Coordinates the user entered. While set they are `coordinate`, `isApproximate` is
    /// false and no Core Location request is made.
    var manualCoordinate: (latitude: Double, longitude: Double)? { get }
    func requestWhenInUse()
    /// Stop any in-flight fix. Called when Adaptive turns off so the location hardware is
    /// never left running for a feature nobody is using.
    func cancelRequest()
    /// Set or clear (nil) the manual coordinate and report the change through `onChange`.
    /// Clearing does not request a fix; the owner asks when Adaptive needs one.
    func setManualCoordinate(_ coordinate: (latitude: Double, longitude: Double)?)
}

/// Range checks shared by the CLI, the command handler and the popover's coordinate fields.
enum ManualLocation {
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    static func validate(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, abs(latitude) <= 90 else {
            throw CommandError.invalidInput("Latitude must be a number from -90 to 90.")
        }
        guard longitude.isFinite, abs(longitude) <= 180 else {
            throw CommandError.invalidInput("Longitude must be a number from -180 to 180.")
        }
    }

    /// Typed or command-line text, in decimal degrees (south and west negative).
    static func parse(latitude: String, longitude: String) throws -> (latitude: Double, longitude: Double) {
        let lat = Double(latitude.trimmingCharacters(in: .whitespaces)) ?? .nan
        let lon = Double(longitude.trimmingCharacters(in: .whitespaces)) ?? .nan
        try validate(latitude: lat, longitude: lon)
        return (lat, lon)
    }

    /// Field text for a coordinate: up to four decimals (about 10 m), always with a period
    /// so `parse` reads it back whatever the user's locale.
    static func text(_ degrees: Double) -> String {
        var text = String(format: "%.4f", degrees)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// Core Location wrapper with a time-zone fallback so Adaptive always has *some* coordinate.
///
/// Threading: `CLLocationManager` delivers delegate callbacks on the run loop of the thread
/// that created it, and this object is created on the main actor, so the `nonisolated`
/// delegate entry points can hop straight back onto `MainActor` with `assumeIsolated`.
/// That keeps the whole class main-actor-isolated like the `DisplayManager` that owns it.
@MainActor
final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private enum FixState { case idle, waitingForAuthorization, requesting }

    private let manager: CLLocationManager
    private let defaults: UserDefaults
    private var fixState = FixState.idle
    var wantsFix: Bool { fixState != .idle }
    // nonisolated(unsafe): set once in init on the main actor; read in deinit for cleanup.
    nonisolated(unsafe) private var timeZoneObserver: NSObjectProtocol?
    var onChange: (() -> Void)?
    private(set) var manualCoordinate: (latitude: Double, longitude: Double)?
    /// The Core Location fix (or the time-zone city). Kept current underneath a manual
    /// coordinate so returning to automatic needs no new fix.
    private var automaticCoordinate: (latitude: Double, longitude: Double)?
    private var automaticIsApproximate = false
    var coordinate: (latitude: Double, longitude: Double)? { manualCoordinate ?? automaticCoordinate }
    var isApproximate: Bool { manualCoordinate == nil && automaticIsApproximate }

    init(defaults: UserDefaults = .standard, timeZone: TimeZone = .current,
         manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        self.defaults = defaults
        super.init()
        // Desktop Macs (Studio on ethernet, Wi-Fi off) often cannot satisfy kilometer
        // accuracy. Three-kilometer / city-level is enough for solar elevation and is
        // the accuracy Core Location can actually produce without a Wi-Fi scan.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        if let cached = loadCoordinate(latitudeKey: "redlight.location.lat", longitudeKey: "redlight.location.lon") {
            automaticCoordinate = cached
        } else {
            automaticCoordinate = ApproximateLocation.from(timeZone)
            automaticIsApproximate = true
        }
        // Hand-edited or corrupt values are ignored, leaving automatic location in charge.
        manualCoordinate = loadCoordinate(latitudeKey: "redlight.location.manualLat",
                                          longitudeKey: "redlight.location.manualLon")
        // A laptop that was denied location but flies to another time zone should still
        // move its fallback city. Only matters while the coordinate is the fallback.
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemTimeZoneChanged() }
        }
        manager.delegate = self
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
        // The user's coordinate needs no fix and no permission.
        guard manualCoordinate == nil, fixState == .idle, authorization != .denied else { return }
        fixState = .waitingForAuthorization
        if authorization == .notDetermined {
            // The fix is requested from the authorization callback once the user answers.
            manager.requestWhenInUseAuthorization()
        } else {
            requestFixIfWanted()
        }
    }

    func cancelRequest() {
        fixState = .idle
        manager.stopUpdatingLocation()   // also cancels a pending requestLocation()
    }

    func setManualCoordinate(_ coordinate: (latitude: Double, longitude: Double)?) {
        if let coordinate {
            guard ManualLocation.isValid(latitude: coordinate.latitude, longitude: coordinate.longitude)
            else { return }
            cancelRequest()
            defaults.set(coordinate.latitude, forKey: "redlight.location.manualLat")
            defaults.set(coordinate.longitude, forKey: "redlight.location.manualLon")
        } else {
            defaults.removeObject(forKey: "redlight.location.manualLat")
            defaults.removeObject(forKey: "redlight.location.manualLon")
        }
        manualCoordinate = coordinate
        onChange?()
    }

    // MARK: - CLLocationManagerDelegate (delivered on the creating thread: main)

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        MainActor.assumeIsolated {
            guard fixState == .requesting else { return }
            fixState = .idle
            if let loc = locs.last(where: isValidFix) { accept(loc.coordinate) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated {
            if authorization == .authorized {
                requestFixIfWanted()
            } else if authorization == .denied {
                cancelRequest()
            }
            onChange?()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        let denied = nsError.domain == kCLErrorDomain && nsError.code == CLError.denied.rawValue
        MainActor.assumeIsolated {
            guard fixState == .requesting else { return }
            fixState = .idle
            if denied {
                manager.stopUpdatingLocation()
                onChange?()
            }
            // `kCLErrorLocationUnknown` is routine on a Mac without GPS: the one-shot
            // request has timed out. The time-zone fallback stays in place and
            // `DisplayManager` asks again in an hour, so nothing needs to keep running.
        }
    }

    // MARK: - Private

    private func requestFixIfWanted() {
        guard fixState == .waitingForAuthorization, authorization == .authorized else { return }
        fixState = .requesting
        // The system's last known fix is usually recent and costs nothing. Use it right
        // away; only ask the hardware when it is missing or old enough that the Mac may
        // have moved (solar elevation only needs city-level accuracy).
        if let existing = manager.location, isValidFix(existing) {
            let age = -existing.timestamp.timeIntervalSinceNow
            if age >= 0, age < 15 * 60 { fixState = .idle }
            accept(existing.coordinate)
        }
        guard fixState == .requesting else { return }
        // One-shot: delivers a single fix or a single error (after Core Location's own
        // ~10 s timeout) and stops itself, so the "location in use" arrow never sits in
        // the menu bar for the life of Adaptive on a Mac that can't get a fix.
        manager.requestLocation()
    }

    private func isValidFix(_ location: CLLocation) -> Bool {
        // A negative horizontal accuracy is Core Location's "invalid fix" marker.
        location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
            && ManualLocation.isValid(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    private func accept(_ coordinate: CLLocationCoordinate2D) {
        let lat = coordinate.latitude, lon = coordinate.longitude
        // Solar elevation is insensitive to sub-kilometer moves; skip the redundant
        // re-apply (and the UserDefaults write) when nothing meaningful changed.
        if !automaticIsApproximate, let current = automaticCoordinate,
           abs(current.latitude - lat) < 0.01, abs(current.longitude - lon) < 0.01 {
            return
        }
        automaticCoordinate = (lat, lon)
        automaticIsApproximate = false
        defaults.set(lat, forKey: "redlight.location.lat")
        defaults.set(lon, forKey: "redlight.location.lon")
        onChange?()
    }

    private func loadCoordinate(latitudeKey: String, longitudeKey: String)
        -> (latitude: Double, longitude: Double)?
    {
        func number(_ key: String) -> Double? {
            guard let value = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        guard let lat = number(latitudeKey), let lon = number(longitudeKey),
              ManualLocation.isValid(latitude: lat, longitude: lon) else { return nil }
        return (lat, lon)
    }

    private func systemTimeZoneChanged() {
        // Foundation caches the system zone; drop it so `.current` reflects the new one.
        NSTimeZone.resetSystemTimeZone()
        guard automaticIsApproximate else { return }
        let fresh = ApproximateLocation.from(.current)
        if let current = automaticCoordinate, current == fresh { return }
        automaticCoordinate = fresh
        if manualCoordinate == nil { onChange?() }
    }
}
