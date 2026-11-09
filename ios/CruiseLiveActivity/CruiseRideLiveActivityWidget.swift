import WidgetKit
import SwiftUI
import ActivityKit

// ═══════════════════════════════════════════════════════════════════
//  Cruise RIDE Live Activity — the rider's trip on the Lock Screen and
//  Dynamic Island while the app is backgrounded, the way Lyft shows it
//  (owner 2026-11-09): how long in big ("Llega en 4 min" / "Carlos
//  llegó"), the plate in a white box with the car ("Toyota Camry gris ·
//  Carlos") until pickup and the destination after it, the driver's
//  photo and rating, and the car sliding along the route bar.
//
//  The bar is time-driven: startedAt → dropoffAt with a TimelineView
//  repaint every 1 s, so the car glides between server/app updates
//  without a single push spent on it.
// ═══════════════════════════════════════════════════════════════════

private let rideGold = Color(red: 0.91, green: 0.77, blue: 0.28) // #E8C547

private var rideIsSpanish: Bool {
  Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

// ── Text lines ──────────────────────────────────────────────────────

/// Whole minutes left on the current leg, ceil-rounded like the in-app ETA
/// (a 1.2-min wait reads "2 min"), never floored to a lie.
private func rideMinutesLeft(_ state: CruiseRideActivityAttributes.ContentState, now: Date) -> Int {
  max(0, Int((state.dropoffAt.timeIntervalSince(now) / 60).rounded(.up)))
}

/// The big line: how long, or who is here.
private func rideTitle(_ state: CruiseRideActivityAttributes.ContentState, now: Date) -> String {
  let mins = rideMinutesLeft(state, now: now)
  let name = state.driverName
  switch state.phase {
  case "en_route":
    if mins <= 0 { return rideIsSpanish ? "Llegando" : "Arriving now" }
    return rideIsSpanish ? "Llega en \(mins) min" : "Arriving in \(mins) min"
  case "arrived":
    if name.isEmpty { return rideIsSpanish ? "Tu conductor llegó" : "Your driver is here" }
    return rideIsSpanish ? "\(name) llegó" : "\(name) is here"
  default: // on_trip
    if mins <= 0 { return rideIsSpanish ? "Llegando a tu destino" : "Arriving now" }
    return rideIsSpanish ? "Llegas en \(mins) min" : "Drop-off in \(mins) min"
  }
}

/// The small line under it: the clock time, or where the driver waits.
private func rideSubtitle(_ state: CruiseRideActivityAttributes.ContentState) -> String {
  let time = state.dropoffAt.formatted(date: .omitted, time: .shortened)
  switch state.phase {
  case "en_route":
    return rideIsSpanish ? "Recogida \(time)" : "\(time) pickup"
  case "arrived":
    return rideIsSpanish ? "Te espera en la recogida" : "Waiting at the pickup"
  default: // on_trip
    return rideIsSpanish ? "Destino \(time)" : "\(time) drop-off"
  }
}

/// True once the card passed its staleDate (iOS 16.2+): no update came for
/// 90 min past the time it shows, so its minutes and phase are not true any
/// more. staleDate never REMOVES a card (iOS keeps it up to 12 h); the app
/// ends an orphan on its next open (LiveActivityService.endOrphanRideCard).
private func rideIsStale(_ context: ActivityViewContext<CruiseRideActivityAttributes>) -> Bool {
  if #available(iOS 16.2, *) { return context.isStale }
  return false
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

/// Car disc ─── gold fill ─── destination pin. The car is a glyph on a gold
/// disc (user spec 2026-09-17): the top-down PNG art rendered as an unreadable
/// pale box at bar size — a black car on gold reads as a car at any size and
/// can never fail to render (no asset-catalog dependency). The destination end
/// is the dropoff pin glyph, not a ring.
private struct RideRouteBar: View {
  var state: CruiseRideActivityAttributes.ContentState
  var compact: Bool = false

  // 30 on the lock screen (was 34): the car row took the height, and the
  // lock screen truncates anything taller than 160 pt.
  private var carW: CGFloat { compact ? 26 : 30 }
  private var line: CGFloat { compact ? 3 : 4 }
  private var pinW: CGFloat { compact ? 16 : 20 }

  var body: some View {
    // 1 s repaint (was 30 s): the car GLIDES with the clock between content
    // updates instead of jumping twice a minute.
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
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
          // Destination: the dropoff pin glyph on the line's end
          Image(systemName: "mappin.circle.fill")
            .font(.system(size: pinW, weight: .bold))
            .foregroundColor(rideGold)
            .offset(x: w - pinW)
          // The car: gold disc, black glyph
          ZStack {
            Circle().fill(rideGold)
            Image(systemName: "car.fill")
              .font(.system(size: carW * 0.5, weight: .bold))
              .foregroundColor(.black)
          }
          .frame(width: carW, height: carW)
          .offset(x: carX)
        }
      }
      .frame(height: carW)
    }
  }
}

/// The car the rider looks for on the street: the plate in a white box,
/// then "Toyota Camry gris · Carlos".
private struct RideCarRow: View {
  var state: CruiseRideActivityAttributes.ContentState
  var compact: Bool = false

  private var detail: String {
    [state.carLine, state.driverName].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 8) {
      if !state.plate.isEmpty {
        Text(state.plate)
          .kerning(0.8)
          .font(.system(size: compact ? 13 : 15, weight: .heavy))
          .foregroundColor(.black)
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, compact ? 6 : 8)
          .padding(.vertical, compact ? 2 : 4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
      }
      Text(detail)
        .font(.system(size: compact ? 12 : 14, weight: .semibold))
        .foregroundColor(.white.opacity(0.88))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }
}

private struct RideCard: View {
  var state: CruiseRideActivityAttributes.ContentState
  var compact: Bool = false
  var stale: Bool = false

  /// Until pickup the car and its plate are what matter; aboard, the
  /// destination. An activity from an older build has neither car field.
  private var showsCar: Bool {
    state.phase != "on_trip" && !(state.plate.isEmpty && state.carLine.isEmpty)
  }

  var body: some View {
    if stale {
      // Never "Llega en 0 min" on a trip that is over or went silent.
      HStack(alignment: .center, spacing: 10) {
        CruiseLogoView(size: compact ? 26 : 36)
        Text(rideIsSpanish ? "Abre Cruise para ver tu viaje" : "Open Cruise to see your trip")
          .font(.system(size: compact ? 14 : 17, weight: .heavy))
          .foregroundColor(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.7)
        Spacer(minLength: 0)
      }
    } else {
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack(alignment: .top, spacing: 10) {
        CruiseLogoView(size: compact ? 26 : 36)
        VStack(alignment: .leading, spacing: 2) {
          // The minutes count down on the same 1 s tick as the bar.
          TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(rideTitle(state, now: ctx.date))
              .font(.system(size: compact ? 16 : 21, weight: .heavy))
              .foregroundColor(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
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
      if showsCar {
        RideCarRow(state: state, compact: compact)
      } else if !state.dropoffAddress.isEmpty {
        Text(state.dropoffAddress)
          .font(.system(size: compact ? 11 : 13, weight: .semibold))
          .foregroundColor(.white.opacity(0.75))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      // The island's 96 pt hold the title and the car, not the bar too;
      // the minutes stay in its compact trailing slot.
      if !compact || !showsCar {
        RideRouteBar(state: state, compact: compact)
      }
    }
    .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
    }
  }
}

/// Compact trailing: the minutes left, recomputed on the same 1 s tick
/// as the bar. Ceil-rounded like the in-app ETA (a 1.2-min wait reads
/// "2 min" on both), never floored to a lie. The slot is a few characters
/// wide, so it may shrink.
private struct RideEtaMinutes: View {
  var state: CruiseRideActivityAttributes.ContentState
  var stale: Bool = false
  var body: some View {
    if stale {
      Text("")
    } else {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let mins = max(0, Int((state.dropoffAt.timeIntervalSince(ctx.date) / 60).rounded(.up)))
      Text("\(mins) min")
        .font(.system(size: 14, weight: .heavy))
        .foregroundColor(rideGold)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    }
  }
}

struct CruiseRideLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CruiseRideActivityAttributes.self) { context in
      // ── Lock Screen banner ──
      RideCard(state: context.state, stale: rideIsStale(context))
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.86))
        .activitySystemActionForegroundColor(rideGold)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          RideCard(state: context.state, compact: true, stale: rideIsStale(context))
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
        RideEtaMinutes(state: context.state, stale: rideIsStale(context))
      } minimal: {
        CruiseLogoView(size: 22)
      }
      .keylineTint(rideGold)
    }
  }
}
