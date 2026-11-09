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
    CruiseRideLiveActivityWidget()
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
//  ride comes in (modelled on the Uber driver widget, in Cruise gold).
//
//  Top row:  logo · fare big with the hourly rate UNDER it as plain
//            text ("$33.49/hr est. rate for this ride" — no gold pill,
//            driver spec 2026-08-22) · miles with minutes under them.
//            The block hugs the TOP edge of the surface, never the
//            middle.
//  Bottom:   car ── pickup ── dropoff, one thin line with slightly
//            larger stops (same spec).
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
  // 32/42 caps on a 3/4 line (driver spec 2026-08-22): a thin thread
  // with slightly larger stops, instead of the old 28/38 on 5/6 where
  // the line fought the caps for attention.
  private var cap: CGFloat { compact ? 32 : 42 }
  private var line: CGFloat { compact ? 3 : 4 }

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

  private var estRateLine: String {
    isSpanish ? "tarifa est. de este viaje" : "est. rate for this ride"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      HStack(alignment: .top, spacing: 10) {
        CruiseLogoView(size: compact ? 30 : 40)
        VStack(alignment: .leading, spacing: 3) {
          Text(state.fare.isEmpty
            ? (isSpanish ? "Nueva oferta" : "New Ride Offer")
            : state.fare)
            .font(.system(
              size: state.fare.isEmpty
                ? (compact ? 17 : 21)
                : (compact ? 30 : 38),
              weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          if !state.perHour.isEmpty {
            // Plain text, not the gold pill (driver spec 2026-08-22):
            // the boxed rate read as a second price tag; the sentence
            // reads as what it is — an estimate.
            Text("\(state.perHour) \(estRateLine)")
              .font(.system(size: compact ? 12 : 14, weight: .semibold))
              .foregroundColor(.white.opacity(0.6))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 1) {
          Text(state.miles)
            .font(.system(size: compact ? 16 : 19, weight: .heavy))
            .foregroundColor(.white)
          Text(state.minutes)
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
        }
        // Both inherit these. Anything over an hour arrives from Dart as
        // "1 h 20 min" instead of "80 min", which is wide enough to push
        // the fare off the row without a floor to shrink into.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }
      // Banner only: the lock screen hands the banner a fixed height and
      // centres whatever it is given, so this Spacer claims the height —
      // money row on the top edge, route bar on the bottom one. The
      // island's expanded region is sized and top-aligned at the call
      // site instead; a Spacer here would stretch the region open.
      if !compact { Spacer(minLength: 0) }
      OfferRouteBar(compact: compact)
    }
    .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Driver card (owner-approved drawing 2026-11-09,
//  https://claude.ai/artifact/DoSsRsv83hW7ULJWJgoetK §5): Lyft's idea —
//  in big, what the driver does next and how long; under it the address
//  (or the pickup code to ask for); the leg's bar; and the closed island
//  with the one number that matters now.
//    online      Buscando viajes · En línea 1 h 12 min · $84.50 hoy
//    to_pickup   Recoge a María en 4 min · Recogida 3:42 PM · address
//    waiting     Esperando a María · Espera gratis 3:12 · luego $0.40/min
//    to_stop     Parada en 3 min        at_stop  Esperando a María en la parada
//    to_dropoff  Deja a María en 12 min · Llegada 3:58 PM · address
//    done        Ganaste $14.20 · Viaje con María · Hoy $98.70 · 5 viajes
// ═══════════════════════════════════════════════════════════════════

private typealias DriverState = CruiseActivityAttributes.ContentState

/// Whole minutes left on the leg, ceil-rounded like every ETA in the app.
private func driverMinutesLeft(_ end: Date?, now: Date) -> Int? {
  guard let end = end else { return nil }
  return max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
}

/// "1 h 12 min" / "45 min" online.
private func driverOnlineFor(_ since: Date?, now: Date) -> String {
  guard let since = since else { return "" }
  let mins = max(0, Int(now.timeIntervalSince(since) / 60))
  let h = mins / 60
  let m = mins % 60
  return h == 0 ? "\(m) min" : "\(h) h \(m) min"
}

/// "3:12" — the free wait left, or the paid wait so far.
private func driverClock(_ seconds: Int) -> String {
  let v = max(0, seconds)
  return String(format: "%d:%02d", v / 60, v % 60)
}

private func driverIsMoving(_ s: DriverState) -> Bool {
  s.phase == "to_pickup" || s.phase == "to_stop" || s.phase == "to_dropoff"
}

private func driverIsWaiting(_ s: DriverState) -> Bool {
  s.phase == "waiting" || s.phase == "at_stop"
}

/// The big line: what the driver does next.
private func driverTitle(_ s: DriverState, now: Date) -> String {
  let who = s.riderName
  // nil = no time yet (the leg just began): say what to do, never
  // "Llegando" — that is for 0 min, at the door.
  let known = driverMinutesLeft(s.legEnd, now: now)
  let mins = known ?? 0
  switch s.phase {
  case "to_pickup":
    if known == nil {
      if who.isEmpty { return isSpanish ? "Ve a la recogida" : "Head to the pickup" }
      return isSpanish ? "Recoge a \(who)" : "Pick up \(who)"
    }
    if mins > 0 {
      if who.isEmpty { return isSpanish ? "Recogida en \(mins) min" : "Pickup in \(mins) min" }
      return isSpanish ? "Recoge a \(who) en \(mins) min" : "Pick up \(who) in \(mins) min"
    }
    return isSpanish ? "Llegando a la recogida" : "Arriving at pickup"
  case "waiting":
    if who.isEmpty { return isSpanish ? "Esperando al pasajero" : "Waiting for your rider" }
    return isSpanish ? "Esperando a \(who)" : "Waiting for \(who)"
  case "to_stop":
    if known == nil { return isSpanish ? "Ve a la parada" : "Head to the stop" }
    if mins > 0 { return isSpanish ? "Parada en \(mins) min" : "Stop in \(mins) min" }
    return isSpanish ? "Llegando a la parada" : "Arriving at the stop"
  case "at_stop":
    if who.isEmpty { return isSpanish ? "Esperando en la parada" : "Waiting at the stop" }
    return isSpanish ? "Esperando a \(who) en la parada" : "Waiting for \(who) at the stop"
  case "to_dropoff":
    if known == nil {
      if who.isEmpty { return isSpanish ? "Ve al destino" : "Head to the drop-off" }
      return isSpanish ? "Deja a \(who) en su destino" : "Drop off \(who)"
    }
    if mins > 0 {
      if who.isEmpty { return isSpanish ? "Destino en \(mins) min" : "Drop-off in \(mins) min" }
      return isSpanish ? "Deja a \(who) en \(mins) min" : "Drop off \(who) in \(mins) min"
    }
    return isSpanish ? "Llegando al destino" : "Arriving at drop-off"
  case "done":
    if s.tripEarned.isEmpty { return isSpanish ? "Viaje terminado" : "Ride complete" }
    return isSpanish ? "Ganaste \(s.tripEarned)" : "You earned \(s.tripEarned)"
  default:
    if s.status == "on_trip" { return isSpanish ? "En viaje" : "On a trip" }
    return isSpanish ? "Buscando viajes" : "Looking for rides"
  }
}

/// The small line under it. The waits draw their own (a live clock).
private func driverSubtitle(_ s: DriverState, now: Date) -> String {
  let time = s.legEnd?.formatted(date: .omitted, time: .shortened) ?? ""
  switch s.phase {
  case "to_pickup":
    return time.isEmpty ? "" : (isSpanish ? "Recogida \(time)" : "\(time) pickup")
  case "to_stop", "to_dropoff":
    return time.isEmpty ? "" : (isSpanish ? "Llegada \(time)" : "Arrive \(time)")
  case "done":
    if s.riderName.isEmpty { return "" }
    return isSpanish ? "Viaje con \(s.riderName)" : "Ride with \(s.riderName)"
  case "waiting", "at_stop":
    return ""
  default:
    if s.status == "on_trip" { return "" }
    let dur = driverOnlineFor(s.onlineSince, now: now)
    if dur.isEmpty { return statusLine(s.status) }
    return isSpanish ? "En línea · \(dur)" : "Online · \(dur)"
  }
}

/// "$84.50 hoy · 4 viajes" (online) / "Hoy $98.70 · 5 viajes" (done).
private func driverEarningsText(_ s: DriverState, compact: Bool) -> Text {
  let n = s.tripsToday
  let rides = isSpanish ? (n == "1" ? "viaje" : "viajes") : (n == "1" ? "ride" : "rides")
  let tail = n.isEmpty ? "" : " · \(n) \(rides)"
  let money = Text(s.earnedToday).bold().foregroundColor(cruiseGold)
  if s.phase == "done" {
    return Text(isSpanish ? "Hoy " : "Today ") + money + Text(tail)
  }
  return money + Text(isSpanish ? " hoy" : " today") + Text(tail)
}

/// The free wait, ticking: "Espera gratis 3:12 · luego $0.40/min", then
/// "Cobrando espera · $0.40/min".
private struct DriverWaitLine: View {
  var state: DriverState
  var compact: Bool
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      if let end = state.freeWaitEnd, end > ctx.date {
        let left = driverClock(Int(end.timeIntervalSince(ctx.date).rounded(.up)))
        let rate = state.waitRate.isEmpty ? ""
          : (isSpanish ? " · luego \(state.waitRate)" : " · then \(state.waitRate)")
        Text((isSpanish ? "Espera gratis " : "Free wait ") + left + rate)
      } else if state.freeWaitEnd != nil {
        Text(isSpanish ? "Cobrando espera · \(state.waitRate)" : "Wait fee · \(state.waitRate)")
      } else {
        Text(isSpanish ? "En la recogida" : "At the pickup")
      }
    }
    .font(.system(size: compact ? 11 : 13, weight: .semibold))
    .foregroundColor(.white.opacity(0.6))
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }
}

/// The rider's face (or a gold initial) and rating.
private struct DriverRiderBadge: View {
  var state: DriverState
  var size: CGFloat

  private var placeholder: some View {
    ZStack {
      Circle().fill(cruiseGold)
      Text(String(state.riderName.prefix(1)).uppercased())
        .font(.system(size: size * 0.45, weight: .heavy))
        .foregroundColor(.black)
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let u = URL(string: state.riderPhotoUrl), !state.riderPhotoUrl.isEmpty {
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
        placeholder.frame(width: size, height: size)
      }
      if !state.riderRating.isEmpty {
        HStack(spacing: 2) {
          Image(systemName: "star.fill")
            .font(.system(size: size * 0.28))
            .foregroundColor(cruiseGold)
          Text(state.riderRating)
            .font(.system(size: size * 0.32, weight: .semibold))
            .foregroundColor(.white.opacity(0.7))
        }
      }
    }
  }
}

/// Car ── leg ── end: the car glides with the clock between updates;
/// waiting pins it at the end.
private struct DriverLegBar: View {
  var state: DriverState
  var compact: Bool = false

  private var carW: CGFloat { compact ? 26 : 30 }
  private var line: CGFloat { compact ? 3 : 4 }
  private var pinW: CGFloat { compact ? 16 : 18 }

  private func fraction(_ now: Date) -> Double {
    if driverIsWaiting(state) { return 1 }
    guard let start = state.legStart, let end = state.legEnd else { return 0 }
    let total = end.timeIntervalSince(start)
    guard total > 0 else { return 1 }
    return min(max(now.timeIntervalSince(start) / total, 0), 1)
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let f = fraction(ctx.date)
      GeometryReader { geo in
        let w = geo.size.width
        let carX = f * (w - carW)
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(height: line)
            .padding(.horizontal, carW / 2)
          Capsule()
            .fill(cruiseGold)
            .frame(width: carX + carW / 2, height: line)
            .padding(.leading, carW / 2)
          Image(systemName: state.phase == "to_pickup" || state.phase == "waiting"
                ? "person.circle.fill" : "mappin.circle.fill")
            .font(.system(size: pinW, weight: .bold))
            .foregroundColor(cruiseGold)
            .offset(x: w - pinW)
          ZStack {
            Circle().fill(cruiseGold)
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

private struct DriverCard: View {
  var state: DriverState
  var compact: Bool = false

  private var onTrip: Bool { driverIsMoving(state) || driverIsWaiting(state) }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack(alignment: .top, spacing: 10) {
        CruiseLogoView(size: compact ? 26 : 36)
        VStack(alignment: .leading, spacing: 2) {
          // The minutes and the time online count on a 1 s tick.
          TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(driverTitle(state, now: ctx.date))
              .font(.system(size: compact ? 16 : 21, weight: .heavy))
              .foregroundColor(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          if driverIsWaiting(state) {
            DriverWaitLine(state: state, compact: compact)
          } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
              Text(driverSubtitle(state, now: ctx.date))
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
          }
        }
        Spacer(minLength: 4)
        if onTrip {
          DriverRiderBadge(state: state, size: compact ? 26 : 34)
        } else {
          Circle()
            .fill(cruiseGold)
            .frame(width: 10, height: 10)
            .padding(.top, compact ? 8 : 12)
        }
      }
      if state.phase == "waiting" {
        // The code is the only unlock for "Desliza para recoger" (rule 58).
        (Text(isSpanish ? "Pídele el " : "Ask for the ")
          + Text(isSpanish ? "código de recogida" : "pickup code").bold().foregroundColor(cruiseGold))
          .font(.system(size: compact ? 12 : 14, weight: .semibold))
          .foregroundColor(.white.opacity(0.88))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .padding(.horizontal, 10)
          .padding(.vertical, compact ? 3 : 6)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(cruiseGold.opacity(0.12)))
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(cruiseGold.opacity(0.45), lineWidth: 1))
      } else if onTrip && !state.address.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: state.phase == "to_pickup" ? "circle.fill" : "square.fill")
            .font(.system(size: compact ? 7 : 9))
            .foregroundColor(cruiseGold)
          Text(state.address)
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundColor(.white.opacity(0.88))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      } else if !onTrip && !state.earnedToday.isEmpty {
        driverEarningsText(state, compact: compact)
          .font(.system(size: compact ? 12 : 14, weight: .regular))
          .foregroundColor(.white.opacity(0.75))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      // The island's 96 pt hold the title and the row; its closed slot
      // already carries the minutes.
      if onTrip && !compact {
        DriverLegBar(state: state, compact: compact)
      }
    }
    .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
  }
}

// Collapsed, the island has room for one fact. During an offer that fact
// is the money; otherwise it is the "you are online" dot. The slot is
// only a few characters wide, so the fare has to be allowed to shrink —
// at a fixed 15 pt heavy, "$24.50" truncates to "$24…".
private struct IslandCompactTrailing: View {
  var state: CruiseActivityAttributes.ContentState

  /// Minutes on a leg, the free wait's clock (then the paid wait counting
  /// up), "+$14.20" after a ride, today's money while online.
  private func label(_ now: Date) -> String? {
    if driverIsMoving(state), let m = driverMinutesLeft(state.legEnd, now: now) {
      return "\(m) min"
    }
    if driverIsWaiting(state), let end = state.freeWaitEnd {
      let left = Int(end.timeIntervalSince(now).rounded(.up))
      return left > 0 ? driverClock(left) : "+" + driverClock(-left)
    }
    if state.phase == "done" && !state.tripEarned.isEmpty { return "+" + state.tripEarned }
    if state.status == "online" && !state.earnedToday.isEmpty { return state.earnedToday }
    return nil
  }

  var body: some View {
    if state.status == "offer" && !state.fare.isEmpty {
      Text(state.fare)
        .font(.system(size: 15, weight: .heavy))
        .foregroundColor(cruiseGold)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { ctx in
        if let text = label(ctx.date) {
          Text(text)
            .font(.system(size: 15, weight: .heavy))
            .foregroundColor(cruiseGold)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        } else {
          Circle()
            .fill(cruiseGold)
            .frame(width: 8, height: 8)
        }
      }
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
          DriverCard(state: context.state)
        }
      }
      .padding(14)
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
              // Fixed height, top-aligned (driver spec 2026-08-22): the
              // region centres its content vertically, which left the
              // money floating in the middle of the island. 98 pt covers
              // the two-line fare block (fare 30 + rate line) plus the
              // 32 pt route bar; top alignment keeps the fare where the
              // eye lands first.
              .frame(height: 98, alignment: .top)
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
      // Online, on a trip, just finished: the driver card, compact, as one
      // piece in the bottom region — fixed height, top-aligned, like the
      // offer (the region centres content vertically otherwise).
      return DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          DriverCard(state: state, compact: true)
            .padding(.horizontal, 4)
            .frame(height: 96, alignment: .top)
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
  }
}
