import WidgetKit
import SwiftUI
import ActivityKit

// ═══════════════════════════════════════════════════════════════════
//  Cruise Live Activity — Dynamic Island + Lock Screen while the
//  driver is online (user spec 2026-08-04: the Cruise logo instead of
//  a bare location arrow when they switch to another app).
//
//  The extension's deployment target is iOS 16.1, so no availability
//  guards are needed inside this file. Devices without the island
//  (iPhone 13 and older) get the Lock Screen banner only.
// ═══════════════════════════════════════════════════════════════════

private let cruiseGold = Color(red: 0.91, green: 0.77, blue: 0.28) // #E8C547

private var isSpanish: Bool {
  Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

private func statusLine(_ status: String) -> String {
  if status == "on_trip" {
    return isSpanish ? "En viaje" : "On a trip"
  }
  return isSpanish ? "En línea — recibiendo viajes" : "Online — receiving trips"
}

@main
struct CruiseLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    CruiseLiveActivityWidget()
  }
}

struct CruiseLogoView: View {
  var size: CGFloat
  var body: some View {
    Image("CruiseLogo")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .clipShape(Circle())
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Offer card — what the driver sees from inside another app when a
//  ride comes in (user spec 2026-08-06, modelled on the Uber driver
//  widget but in Cruise gold).
//
//  Top row:  logo · fare · gold pill with the hourly rate · miles with
//            minutes under them.
//  Bottom:   car ── pickup ── dropoff, a route drawn as one line. The
//            distance and time are NOT repeated at the dropoff end the
//            way Uber does it: they are already up top, and this strip
//            is 60 pt tall on a lock screen.
// ═══════════════════════════════════════════════════════════════════

private struct OfferEndCap: View {
  var systemName: String
  var size: CGFloat
  var body: some View {
    ZStack {
      Circle().fill(cruiseGold)
      Image(systemName: systemName)
        .font(.system(size: size * 0.5, weight: .bold))
        .foregroundColor(.black)
    }
    .frame(width: size, height: size)
  }
}

private struct OfferRouteBar: View {
  var compact: Bool = false
  private var cap: CGFloat { compact ? 22 : 30 }
  private var line: CGFloat { compact ? 4 : 5 }

  var body: some View {
    HStack(spacing: 0) {
      OfferEndCap(systemName: "car.fill", size: cap)
      Capsule().fill(cruiseGold).frame(height: line)
      // Pickup: a hollow ring on the line, the way a stop reads on a
      // route rather than another destination.
      ZStack {
        Circle().fill(Color.black.opacity(0.9))
        Circle().strokeBorder(cruiseGold, lineWidth: line * 0.6)
        Image(systemName: "figure.wave")
          .font(.system(size: cap * 0.42, weight: .bold))
          .foregroundColor(cruiseGold)
      }
      .frame(width: cap, height: cap)
      Capsule().fill(cruiseGold).frame(height: line)
      OfferEndCap(systemName: "mappin", size: cap)
    }
  }
}

private struct OfferCard: View {
  var state: CruiseActivityAttributes.ContentState
  var compact: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(alignment: .center, spacing: 10) {
        CruiseLogoView(size: compact ? 26 : 34)
        // The money the driver is being offered, in the size Uber gives
        // its hourly rate: it is the one number the decision turns on.
        Text(state.fare)
          .font(.system(size: compact ? 26 : 34, weight: .heavy))
          .foregroundColor(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if !state.perHour.isEmpty {
          // Dart hands this over localised and to the cent ("$32.45/hr",
          // "$32.45/h"), so it is half again as wide as the whole-dollar
          // string this row was first laid out for. Scale rather than
          // truncate: a rate missing its last digit is worse than a small
          // one. The scale sits on the Text so the capsule hugs whatever
          // width it settles at, and the compact pill gives back 2 pt of
          // side padding — in the island that is about one character.
          Text(state.perHour)
            .font(.system(size: compact ? 13 : 15, weight: .heavy))
            .foregroundColor(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(Capsule().fill(cruiseGold))
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 1) {
          Text(state.miles)
            .font(.system(size: compact ? 14 : 17, weight: .heavy))
            .foregroundColor(.white)
          Text(state.minutes)
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
        }
        // Both inherit these. Anything over an hour arrives from Dart as
        // "1 h 20 min" instead of "80 min", which is wide enough to push
        // the fare off the row without a floor to shrink into.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }
      OfferRouteBar(compact: compact)
    }
  }
}

// Collapsed, the island has room for one fact. During an offer that fact
// is the money; otherwise it is the "you are online" dot. The slot is
// only a few characters wide, so the fare has to be allowed to shrink —
// at a fixed 15 pt heavy, "$24.50" truncates to "$24…".
private struct IslandCompactTrailing: View {
  var state: CruiseActivityAttributes.ContentState
  var body: some View {
    if state.status == "offer" && !state.fare.isEmpty {
      Text(state.fare)
        .font(.system(size: 15, weight: .heavy))
        .foregroundColor(cruiseGold)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    } else {
      Circle()
        .fill(cruiseGold)
        .frame(width: 8, height: 8)
    }
  }
}

struct CruiseLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CruiseActivityAttributes.self) { context in
      // ── Lock Screen banner ──
      Group {
        if context.state.status == "offer" {
          OfferCard(state: context.state)
        } else {
          HStack(spacing: 12) {
            CruiseLogoView(size: 42)
            VStack(alignment: .leading, spacing: 2) {
              Text("Cruise")
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
              Text(statusLine(context.state.status))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(cruiseGold)
            }
            Spacer()
            Circle()
              .fill(cruiseGold)
              .frame(width: 10, height: 10)
          }
        }
      }
      .padding(16)
      .activityBackgroundTint(Color.black.opacity(0.86))
      .activitySystemActionForegroundColor(cruiseGold)
    } dynamicIsland: { context in
      // Two whole DynamicIslands rather than one with an if/else over the
      // regions: DynamicIslandExpandedContentBuilder is documented with
      // buildBlock overloads only, so a conditional region set is not
      // something to bet a release on. DynamicIsland is not generic — the
      // generics sit on its initialiser — so both branches are the same
      // type and this closure still returns a single DynamicIsland.
      let state = context.state
      if state.status == "offer" {
        // An offer needs the full width for the fare, the rate and the
        // route bar, so it takes the bottom region as one piece instead
        // of being cut into three columns.
        return DynamicIsland {
          DynamicIslandExpandedRegion(.bottom) {
            OfferCard(state: state, compact: true)
              .padding(.horizontal, 4)
              .padding(.top, 2)
          }
        } compactLeading: {
          CruiseLogoView(size: 23)
        } compactTrailing: {
          IslandCompactTrailing(state: state)
        } minimal: {
          CruiseLogoView(size: 22)
        }
        .keylineTint(cruiseGold)
      }
      // Online / on a trip: the three-column layout that already ships.
      // Keeping this content in .bottom left the expanded island with an
      // empty top row and everything shoved under it.
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          CruiseLogoView(size: 36)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Cruise")
              .font(.system(size: 15, weight: .heavy))
              .foregroundColor(.white)
            Text(statusLine(state.status))
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(cruiseGold)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Circle()
            .fill(cruiseGold)
            .frame(width: 10, height: 10)
        }
      } compactLeading: {
        CruiseLogoView(size: 23)
      } compactTrailing: {
        IslandCompactTrailing(state: state)
      } minimal: {
        CruiseLogoView(size: 22)
      }
      .keylineTint(cruiseGold)
    }
  }
}
