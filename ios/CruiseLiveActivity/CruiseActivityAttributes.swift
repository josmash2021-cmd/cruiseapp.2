import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Shared between the Runner app (which starts/stops the activity) and the
/// CruiseLiveActivity widget extension (which renders it). This file is a
/// member of BOTH targets in the Xcode project — the type identity must
/// match on each side for ActivityKit to route updates.
@available(iOS 16.1, *)
struct CruiseActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// "online" while waiting for offers, "offer" while one is on screen,
    /// "on_trip" during an active trip.
    var status: String
    /// When the driver went online — lets the UI show elapsed time later.
    var since: Date

    // ── Offer fields ──
    // Empty unless status == "offer". Strings, not numbers: the money, the
    // units and the rounding are formatted once in Dart, where the locale
    // and the per-tier rate already live. The widget renders what it is
    // handed and never does arithmetic — a second formatter here would be a
    // second place for the driver's pay to disagree with itself.
    var fare: String = ""
    var perHour: String = ""
    var miles: String = ""
    var minutes: String = ""

    private enum CodingKeys: String, CodingKey {
      case status, since, fare, perHour, miles, minutes
    }

    // Written out because declaring init(from:) below suppresses the
    // memberwise one.
    init(
      status: String,
      since: Date,
      fare: String = "",
      perHour: String = "",
      miles: String = "",
      minutes: String = ""
    ) {
      self.status = status
      self.since = since
      self.fare = fare
      self.perHour = perHour
      self.miles = miles
      self.minutes = minutes
    }

    // The property defaults above are NOT a decoding fallback: Swift's
    // synthesised init(from:) throws .keyNotFound on a missing key and
    // never consults them. Only decodeIfPresent gives the four offer
    // fields backwards compatibility, so an activity that the previous
    // two-field build left running still decodes after the app updates
    // instead of vanishing from the island.
    //
    // public because it witnesses a requirement of Decodable on a public
    // type; the memberwise init above stays internal, the way the
    // synthesised one was.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      status = try c.decode(String.self, forKey: .status)
      since = try c.decode(Date.self, forKey: .since)
      fare = try c.decodeIfPresent(String.self, forKey: .fare) ?? ""
      perHour = try c.decodeIfPresent(String.self, forKey: .perHour) ?? ""
      miles = try c.decodeIfPresent(String.self, forKey: .miles) ?? ""
      minutes = try c.decodeIfPresent(String.self, forKey: .minutes) ?? ""
    }
  }
}
#endif
