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

    // ── Trip and shift fields (owner-approved drawing 2026-11-09) ──
    // What the driver does next, in big, the way Lyft writes its rider
    // card. `status` keeps its old values so a card painted by a newer app
    // on an older widget still reads "En viaje"; `phase` refines it:
    // "to_pickup" · "waiting" · "to_stop" · "at_stop" · "to_dropoff" while
    // on_trip, "done" (just finished) while online.
    var phase: String = ""
    var riderName: String = ""
    var riderRating: String = ""
    var riderPhotoUrl: String = ""
    /// The address of the current leg (pickup, stop or dropoff).
    var address: String = ""
    /// The current leg, start → arrival: the minutes and the bar.
    var legStart: Date? = nil
    var legEnd: Date? = nil
    /// When the free wait ends at the pickup or the stop.
    var freeWaitEnd: Date? = nil
    /// "$0.40/min" — the wait fee after the free minutes.
    var waitRate: String = ""
    /// Today's money and rides: "$84.50", "4".
    var earnedToday: String = ""
    var tripsToday: String = ""
    /// What the ride that just ended paid: "$14.20".
    var tripEarned: String = ""
    /// The shift's real start (`since` is reset on every update).
    var onlineSince: Date? = nil

    private enum CodingKeys: String, CodingKey {
      case status, since, fare, perHour, miles, minutes
      case phase, riderName, riderRating, riderPhotoUrl, address
      case legStart, legEnd, freeWaitEnd, waitRate
      case earnedToday, tripsToday, tripEarned, onlineSince
    }

    // Written out because declaring init(from:) below suppresses the
    // memberwise one.
    init(
      status: String,
      since: Date,
      fare: String = "",
      perHour: String = "",
      miles: String = "",
      minutes: String = "",
      phase: String = "",
      riderName: String = "",
      riderRating: String = "",
      riderPhotoUrl: String = "",
      address: String = "",
      legStart: Date? = nil,
      legEnd: Date? = nil,
      freeWaitEnd: Date? = nil,
      waitRate: String = "",
      earnedToday: String = "",
      tripsToday: String = "",
      tripEarned: String = "",
      onlineSince: Date? = nil
    ) {
      self.status = status
      self.since = since
      self.fare = fare
      self.perHour = perHour
      self.miles = miles
      self.minutes = minutes
      self.phase = phase
      self.riderName = riderName
      self.riderRating = riderRating
      self.riderPhotoUrl = riderPhotoUrl
      self.address = address
      self.legStart = legStart
      self.legEnd = legEnd
      self.freeWaitEnd = freeWaitEnd
      self.waitRate = waitRate
      self.earnedToday = earnedToday
      self.tripsToday = tripsToday
      self.tripEarned = tripEarned
      self.onlineSince = onlineSince
    }

    // The property defaults above are NOT a decoding fallback: Swift's
    // synthesised init(from:) throws .keyNotFound on a missing key and
    // never consults them. Only decodeIfPresent gives the newer fields
    // backwards compatibility, so an activity that an older build left
    // running — or a server push that carries only the offer fields —
    // still decodes instead of vanishing from the island.
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
      phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
      riderName = try c.decodeIfPresent(String.self, forKey: .riderName) ?? ""
      riderRating = try c.decodeIfPresent(String.self, forKey: .riderRating) ?? ""
      riderPhotoUrl = try c.decodeIfPresent(String.self, forKey: .riderPhotoUrl) ?? ""
      address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
      legStart = try c.decodeIfPresent(Date.self, forKey: .legStart)
      legEnd = try c.decodeIfPresent(Date.self, forKey: .legEnd)
      freeWaitEnd = try c.decodeIfPresent(Date.self, forKey: .freeWaitEnd)
      waitRate = try c.decodeIfPresent(String.self, forKey: .waitRate) ?? ""
      earnedToday = try c.decodeIfPresent(String.self, forKey: .earnedToday) ?? ""
      tripsToday = try c.decodeIfPresent(String.self, forKey: .tripsToday) ?? ""
      tripEarned = try c.decodeIfPresent(String.self, forKey: .tripEarned) ?? ""
      onlineSince = try c.decodeIfPresent(Date.self, forKey: .onlineSince)
    }
  }
}
#endif
