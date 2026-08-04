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
    /// "online" while waiting for offers, "on_trip" during an active trip.
    var status: String
    /// When the driver went online — lets the UI show elapsed time later.
    var since: Date
  }
}
#endif
