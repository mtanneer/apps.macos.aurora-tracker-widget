import CoreLocation
import Observation

/// App-only: requests when-in-use authorization and a single location fix on demand.
/// Not continuous tracking — this powers a "chance tonight" lookup, not live tracking.
/// The widget never uses this directly; it reads the last location cached to the
/// App Group by the app (see `CachedLocation`).
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Status {
        case notDetermined, denied, authorized
    }

    /// A fix that hasn't arrived by now isn't coming (Location Services off, no signal).
    static let fixTimeout: Duration = .seconds(10)

    var status: Status = .notDetermined
    var lastLocation: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    // Waiter lists, not single slots: overlapping callers (launch task + a button tap) must
    // each be resumed, and only the first triggers the underlying CoreLocation request.
    private var authWaiters: [CheckedContinuation<Status, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []
    private var fixTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        status = Self.status(for: manager.authorizationStatus)
    }

    /// Requests authorization and waits for the user's decision, then returns the resulting status.
    /// `requestWhenInUseAuthorization()` is fire-and-forget — the OS prompt takes real time to
    /// resolve, so callers that need to act once permission is granted must await this instead.
    func requestAuthorizationAndWait() async -> Status {
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authWaiters.append(continuation)
            if authWaiters.count == 1 {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    /// Requests a single location fix. Returns nil if unauthorized or the fetch fails/times out.
    func fetchLocation() async -> CLLocationCoordinate2D? {
        guard status == .authorized else { return nil }
        return await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            if fixWaiters.count == 1 {
                manager.requestLocation()
                fixTimeoutTask = Task {
                    try? await Task.sleep(for: Self.fixTimeout)
                    if !Task.isCancelled { finishFix(nil) }
                }
            }
        }
    }

    private func finishFix(_ coord: CLLocationCoordinate2D?) {
        fixTimeoutTask?.cancel()
        fixTimeoutTask = nil
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0.resume(returning: coord) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let auth = manager.authorizationStatus
        Task { @MainActor in
            status = Self.status(for: auth)
            if status != .notDetermined {
                let waiters = authWaiters
                authWaiters = []
                waiters.forEach { $0.resume(returning: status) }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        Task { @MainActor in
            lastLocation = coord ?? lastLocation
            if let coord {
                CachedLocation.save(lat: coord.latitude, lon: coord.longitude)
            }
            finishFix(coord)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finishFix(nil) }
    }

    nonisolated private static func status(for auth: CLAuthorizationStatus) -> Status {
        switch auth {
        // macOS reports a granted when-in-use request as either of these.
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied, .restricted:
            return .denied
        default:
            return .notDetermined
        }
    }
}
