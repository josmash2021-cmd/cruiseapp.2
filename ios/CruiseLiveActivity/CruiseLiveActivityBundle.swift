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

struct CruiseLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CruiseActivityAttributes.self) { context in
      // ── Lock Screen banner ──
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
      .padding(16)
      .activityBackgroundTint(Color.black.opacity(0.86))
      .activitySystemActionForegroundColor(cruiseGold)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          CruiseLogoView(size: 36)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Cruise")
              .font(.system(size: 15, weight: .heavy))
              .foregroundColor(.white)
            Text(statusLine(context.state.status))
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
        Circle()
          .fill(cruiseGold)
          .frame(width: 8, height: 8)
      } minimal: {
        CruiseLogoView(size: 22)
      }
      .keylineTint(cruiseGold)
    }
  }
}
