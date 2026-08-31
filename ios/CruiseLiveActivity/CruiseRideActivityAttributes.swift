import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Rider-side Live Activity: the trip on the lock screen / Dynamic Island
/// while the rider's app is backgrounded (Lyft-style: drop-off ETA,
/// destination, driver photo/name/rating, and the car sliding along the
/// progress bar).
///
/// Shared between the Runner app (which starts/stops the activity) and the
/// CruiseLiveActivity widget extension (which renders it). This file is a
/// member of BOTH targets in the Xcode project — the type identity must
/// match on each side for ActivityKit to route updates.
@available(iOS 16.1, *)
struct CruiseRideActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// "en_route" (driver approaching pickup), "arrived" (driver waiting),
    /// "on_trip" (rider aboard, heading to dropoff).
    var phase: String
    /// Bar anchor: when the current leg started (assigned at for en_route,
    /// pickup at for on_trip). The bar is time-driven, see the widget.
    var startedAt: Date
    /// When the current leg ends (pickup ETA for en_route, dropoff ETA
    /// for on_trip). The "4:15 PM drop-off" line reads this.
    var dropoffAt: Date

    // ── Display fields ──
    // All pre-formatted in Dart — the widget never formats money, ratings
    // or addresses itself, so the lock screen and the in-app card can never
    // disagree.
    var dropoffAddress: String = ""
    var driverName: String = ""
    var driverRating: String = ""
    var driverPhotoUrl: String = ""
    /// Asset catalog name of the top-down car PNG: "CarSedan" /
    /// "CarSuv" / "CarEconomy" (same art as the in-app map markers).
    var carImage: String = ""

    private enum CodingKeys: String, CodingKey {
      case phase, startedAt, dropoffAt, dropoffAddress, driverName
      case driverRating, driverPhotoUrl, carImage
    }

    // Written out because declaring init(from:) below suppresses the
    // memberwise one.
    init(
      phase: String,
      startedAt: Date,
      dropoffAt: Date,
      dropoffAddress: String = "",
      driverName: String = "",
      driverRating: String = "",
      driverPhotoUrl: String = "",
      carImage: String = ""
    ) {
      self.phase = phase
      self.startedAt = startedAt
      self.dropoffAt = dropoffAt
      self.dropoffAddress = dropoffAddress
      self.driverName = driverName
      self.driverRating = driverRating
      self.driverPhotoUrl = driverPhotoUrl
      self.carImage = carImage
    }

    // decodeIfPresent on the display fields, never trusting the property
    // defaults: Swift's synthesised init(from:) throws .keyNotFound on a
    // missing key and never consults them. An activity started by an older
    // build must still decode after the app updates instead of vanishing.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      phase = try c.decode(String.self, forKey: .phase)
      startedAt = try c.decode(Date.self, forKey: .startedAt)
      dropoffAt = try c.decode(Date.self, forKey: .dropoffAt)
      dropoffAddress = try c.decodeIfPresent(String.self, forKey: .dropoffAddress) ?? ""
      driverName = try c.decodeIfPresent(String.self, forKey: .driverName) ?? ""
      driverRating = try c.decodeIfPresent(String.self, forKey: .driverRating) ?? ""
      driverPhotoUrl = try c.decodeIfPresent(String.self, forKey: .driverPhotoUrl) ?? ""
      carImage = try c.decodeIfPresent(String.self, forKey: .carImage) ?? ""
    }
  }
}
#endif
