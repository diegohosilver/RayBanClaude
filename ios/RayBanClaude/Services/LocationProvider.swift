import CoreLocation
import Foundation

/// One-time location request for “Where am I?” and “Remember where I parked”.
/// On demand only – the app never tracks the location in the background.
@MainActor
final class LocationProvider: NSObject {
    private let manager = CLLocationManager()
    private var locationWaiter: CheckedContinuation<CLLocation, Error>?
    private var authorizationWaiter: CheckedContinuation<Void, Never>?
    private let timeout: UInt64 = 15_000_000_000 // 15 s

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Readable address (“5 Main Street, 10115 Berlin”) – the coordinates if there is no address
    func currentAddress() async throws -> String {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationWaiter = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else {
            throw LocationError.denied
        }
        let location = try await withCheckedThrowingContinuation { continuation in
            locationWaiter?.resume(throwing: LocationError.unavailable)
            locationWaiter = continuation
            manager.requestLocation()
            Task { [weak self, timeout] in
                try? await Task.sleep(nanoseconds: timeout)
                self?.finish(.failure(LocationError.unavailable))
            }
        }
        return await Self.address(for: location)
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        locationWaiter?.resume(with: result)
        locationWaiter = nil
    }

    private static func address(for location: CLLocation) async -> String {
        let fallback = String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")).first else {
            return fallback
        }
        let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [mark.postalCode, mark.locality].compactMap { $0 }.joined(separator: " ")
        // Name only if it says more than the street (e.g. “Market Square Parking Garage”)
        let name = mark.name.flatMap { $0 == street || $0.isEmpty ? nil : $0 }
        let parts = [name, street.isEmpty ? nil : street, city.isEmpty ? nil : city].compactMap { $0 }
        return parts.isEmpty ? fallback : parts.joined(separator: ", ")
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(LocationError.unavailable)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in
            self.authorizationWaiter?.resume()
            self.authorizationWaiter = nil
        }
    }
}

enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: return "No access to location – allow it in iOS Settings for RayBan Claude"
        case .unavailable: return "Location currently unavailable – briefly unlock the iPhone or try again later"
        }
    }
}
