import WidgetKit
import SwiftUI
import ActivityKit

// ═══════════════════════════════════════════════════════════════════
//  Cruise RIDE Live Activity — the rider's trip on the Lock Screen and
//  Dynamic Island while the app is backgrounded (1:1 with the Lyft
//  reference: drop-off time + destination left, driver photo/name/rating
//  right, and the car sliding along the route bar).
//
//  The bar is time-driven: startedAt → dropoffAt with a TimelineView
//  repaint every 30 s, so the car keeps moving between server/app updates
//  without a single push spent on it.
// ═══════════════════════════════════════════════════════════════════

private let rideGold = Color(red: 0.91, green: 0.77, blue: 0.28) // #E8C547

private var rideIsSpanish: Bool {
  Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

// ── Text lines ──────────────────────────────────────────────────────

private func rideTitle(_ state: CruiseRideActivityAttributes.ContentState) -> String {
  let time = state.dropoffAt.formatted(date: .omitted, time: .shortened)
  switch state.phase {
  case "en_route":
    return rideIsSpanish ? "Recogida \(time)" : "\(time) pickup"
  case "arrived":
    return rideIsSpanish ? "Tu driver llegó" : "Your driver is here"
  default: // on_trip
    return rideIsSpanish ? "Destino \(time)" : "\(time) drop-off"
  }
}

private func rideSubtitle(_ state: CruiseRideActivityAttributes.ContentState) -> String {
  if state.phase == "arrived" {
    return rideIsSpanish ? "Encuentra tu carro en el punto de partida"
                         : "Meet your car at the pickup spot"
  }
  return state.dropoffAddress
}

/// 0…1 along the current leg, time-anchored so it can be recomputed on any
/// repaint. "arrived" pins the car at the far end — the driver is there.
private func rideFraction(_ state: CruiseRideActivityAttributes.ContentState, now: Date) -> Double {
  if state.phase == "arrived" { return 1 }
  let total = state.dropoffAt.timeIntervalSince(state.startedAt)
  guard total > 0 else { return 0 }
  let f = now.timeIntervalSince(state.startedAt) / total
  return min(max(f, 0), 1)
}

// ── Pieces ──────────────────────────────────────────────────────────

/// The driver's face, or a gold initial while the photo loads / if there
/// is none. AsyncImage renders live inside a Live Activity.
private struct RideDriverPhoto: View {
  var url: String
  var name: String
  var size: CGFloat

  private var placeholder: some View {
    ZStack {
      Circle().fill(rideGold)
      Text(String(name.prefix(1)).uppercased())
        .font(.system(size: size * 0.45, weight: .heavy))
        .foregroundColor(.black)
    }
  }

  var body: some View {
    if let u = URL(string: url), !url.isEmpty {
      AsyncImage(url: u) { phase in
        if case .success(let img) = phase {
          img.resizable().scaledToFill()
        } else {
          placeholder
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
    } else {
      placeholder
        .frame(width: size, height: size)
    }
  }
}

/// Car ─── gold fill ─── destination ring. The car PNG is the same
/// top-down art the in-app map markers use (assets/markers → CarSedan /
/// CarSuv / CarEconomy in the extension's asset catalog).
private struct RideRouteBar: View {
  var state: CruiseRideActivityAttributes.ContentState
  var compact: Bool = false

  private var carW: CGFloat { compact ? 30 : 40 }
  private var line: CGFloat { compact ? 3 : 4 }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { ctx in
      let f = rideFraction(state, now: ctx.date)
      GeometryReader { geo in
        let w = geo.size.width
        let carX = f * (w - carW)
        ZStack(alignment: .leading) {
          // Track
          Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(height: line)
            .padding(.horizontal, carW / 2)
          // Fill, up to the car's nose
          Capsule()
            .fill(rideGold)
            .frame(width: carX + carW / 2, height: line)
            .padding(.leading, carW / 2)
          // Destination: hollow ring on the line's end
          Circle()
            .strokeBorder(rideGold, lineWidth: line * 0.6)
            .background(Circle().fill(Color.black.opacity(0.9)))
            .frame(width: line * 3.2, height: line * 3.2)
            .offset(x: w - line * 1.6)
          // The car
          Image(state.carImage.isEmpty ? "CarSedan" : state.carImage)
            .resizable()
            .scaledToFit()
            .frame(width: carW, height: carW)
            .offset(x: carX)
        }
      }
      .frame(height: carW)
    }
  }
}

private struct RideCard: View {
  var state: CruiseRideActivityAttributes.ContentState
  var compact: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(alignment: .top, spacing: 10) {
        CruiseLogoView(size: compact ? 26 : 36)
        VStack(alignment: .leading, spacing: 2) {
          Text(rideTitle(state))
            .font(.system(size: compact ? 15 : 19, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(rideSubtitle(state))
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 2) {
          RideDriverPhoto(
            url: state.driverPhotoUrl,
            name: state.driverName,
            size: compact ? 26 : 34
          )
          Text(state.driverName)
            .font(.system(size: compact ? 10 : 12, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
          if !state.driverRating.isEmpty {
            HStack(spacing: 2) {
              Image(systemName: "star.fill")
                .font(.system(size: compact ? 8 : 10))
                .foregroundColor(rideGold)
              Text(state.driverRating)
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            }
          }
        }
      }
      // Banner only: the lock screen centres whatever it is given, so the
      // Spacer claims the height — title row on top, route bar below.
      if !compact { Spacer(minLength: 0) }
      RideRouteBar(state: state, compact: compact)
    }
    .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
  }
}

/// Compact trailing: the minutes left, recomputed on the same 30 s tick
/// as the bar. The slot is a few characters wide, so it may shrink.
private struct RideEtaMinutes: View {
  var state: CruiseRideActivityAttributes.ContentState
  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { ctx in
      let mins = max(0, Int(state.dropoffAt.timeIntervalSince(ctx.date) / 60))
      Text("\(mins) min")
        .font(.system(size: 14, weight: .heavy))
        .foregroundColor(rideGold)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
  }
}

struct CruiseRideLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CruiseRideActivityAttributes.self) { context in
      // ── Lock Screen banner ──
      RideCard(state: context.state)
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.86))
        .activitySystemActionForegroundColor(rideGold)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          RideCard(state: context.state, compact: true)
            .padding(.horizontal, 4)
            // Fixed height, top-aligned (same lesson as the offer card):
            // the region centres content vertically, which floats the
            // title in the middle of the island.
            .frame(height: 96, alignment: .top)
            .padding(.top, 2)
        }
      } compactLeading: {
        CruiseLogoView(size: 23)
      } compactTrailing: {
        RideEtaMinutes(state: context.state)
      } minimal: {
        CruiseLogoView(size: 22)
      }
      .keylineTint(rideGold)
    }
  }
}
