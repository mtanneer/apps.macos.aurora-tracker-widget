import CoreLocation
import Observation

/// App-only: requests when-in-use authorization and a single location fix on demand.
/// Not continuous tracking — this powers a "chance tonight" lookup, not live tracking.
/// The widget never uses this directly; it reads the last location cached to the
/// App Group by the app (see `CachedLocation`).
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Status {
        case notDetermined, denied, authorized
    }

    var status: Status = .notDetermined
    var lastLocation: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        status = Self.status(for: manager.authorizationStatus)
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requests authorization and waits for the user's decision, then returns the resulting status.
    /// `requestWhenInUseAuthorization()` is fire-and-forget — the OS prompt takes real time to
    /// resolve, so callers that need to act once permission is granted must await this instead.
    func requestAuthorizationAndWait() async -> Status {
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            self.authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private var authContinuation: CheckedContinuation<Status, Never>?

    /// Requests a single location fix. Returns nil if unauthorized or the fetch fails/times out.
    func fetchLocation() async -> CLLocationCoordinate2D? {
        guard status == .authorized else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = Self.status(for: manager.authorizationStatus)
        if status != .notDetermined {
            authContinuation?.resume(returning: status)
            authContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        lastLocation = coord
        if let coord {
            CachedLocation.save(lat: coord.latitude, lon: coord.longitude)
        }
        continuation?.resume(returning: coord)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private static func status(for auth: CLAuthorizationStatus) -> Status {
        switch auth {
        case .authorizedAlways:
            return .authorized
        #if os(iOS)
        case .authorizedWhenInUse:
            return .authorized
        #endif
        case .denied, .restricted:
            return .denied
        default:
            return .notDetermined
        }
    }
}
