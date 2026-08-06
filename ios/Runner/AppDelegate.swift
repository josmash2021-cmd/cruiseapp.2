import UIKit
import Flutter
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    setupLiveActivityChannel()
    // Show notifications even when app is in foreground
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ── Live Activity bridge (driver online → Cruise logo in the Dynamic
  //    Island). Uses the plugin registrar's messenger rather than
  //    window.rootViewController so it works under the UIScene lifecycle
  //    (SceneDelegate owns the window; it may not exist yet here).
  private func setupLiveActivityChannel() {
    guard let registrar = self.registrar(forPlugin: "CruiseLiveActivityChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "cruise/live_activity",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      // 16.2, not 16.1: the modern ActivityKit calls used below
      // (request(content:), update(_:), end(_:dismissalPolicy:)) shipped
      // in 16.2, and using them inside a 16.1 context does not compile.
      guard #available(iOS 16.2, *) else {
        result(false) // older iOS: silently unsupported, never an error
        return
      }
      let args = call.arguments as? [String: Any]
      let status = args?["status"] as? String ?? "online"
      let fare = args?["fare"] as? String ?? ""
      let perHour = args?["perHour"] as? String ?? ""
      let miles = args?["miles"] as? String ?? ""
      let minutes = args?["minutes"] as? String ?? ""
      switch call.method {
      case "start":
        CruiseLiveActivityManager.shared.start(status: status)
        result(true)
      case "update":
        CruiseLiveActivityManager.shared.update(status: status)
        result(true)
      case "offer":
        // A ride offer came in — put it on the running activity. `true`
        // here means the call was accepted, not that the island changed:
        // the work is enqueued and ActivityKit can still refuse it.
        CruiseLiveActivityManager.shared.offer(
          fare: fare, perHour: perHour, miles: miles, minutes: minutes)
        result(true)
      case "stop":
        CruiseLiveActivityManager.shared.stop()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Show notification banner/alert/sound even when app is open
  @available(iOS 10, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  // Handle notification tap
  @available(iOS 10, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}

// ═══════════════════════════════════════════════════════════════════
//  ActivityKit manager — one activity at a time. start() ends any
//  stale activities first (the handle is lost across app restarts, so
//  it sweeps Activity<...>.activities rather than trusting its own
//  reference). Every call is fail-soft: a Live Activity is cosmetic
//  and must never take the driver flow down with it.
// ═══════════════════════════════════════════════════════════════════

#if canImport(ActivityKit)
@available(iOS 16.2, *)
final class CruiseLiveActivityManager {
  static let shared = CruiseLiveActivityManager()
  private var activity: Activity<CruiseActivityAttributes>?

  // Every operation chains on the previous one. Independent detached
  // Tasks raced on quick online→offline toggles: stop()'s sweep could
  // land AFTER start()'s request and kill the fresh activity — or the
  // reverse, leaving the island alive while offline.
  private var chain: Task<Void, Never>?

  private func enqueue(_ op: @escaping () async -> Void) {
    let previous = chain
    chain = Task {
      await previous?.value
      await op()
    }
  }

  func start(status: String) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      // Silent until now, and indistinguishable from our code never running.
      // This is the switch under Settings > Cruise > Live Activities: when it
      // is off nothing we do here can put anything on the lock screen.
      NSLog("[LiveActivity] start refused: Live Activities are disabled for "
        + "this app in Settings — nothing will appear on the lock screen")
      return
    }
    let state = CruiseActivityAttributes.ContentState(status: status, since: Date())
    enqueue {
      // End stale ones (e.g. left over from a force-killed session).
      for stale in Activity<CruiseActivityAttributes>.activities {
        await stale.end(nil, dismissalPolicy: .immediate)
      }
      do {
        self.activity = try Activity.request(
          attributes: CruiseActivityAttributes(),
          content: .init(state: state, staleDate: nil)
        )
      } catch {
        // Denied in Settings, backgrounded, or system limit. Logged because
        // a start that quietly failed is why offer() later finds nothing
        // running.
        NSLog("[LiveActivity] start failed: %@", "\(error)")
      }
    }
  }

  func update(status: String) {
    let state = CruiseActivityAttributes.ContentState(status: status, since: Date())
    enqueue {
      for a in Activity<CruiseActivityAttributes>.activities {
        await a.update(.init(state: state, staleDate: nil))
      }
    }
  }

  /// A ride offer came in — show it on the Live Activity the shift
  /// already started.
  ///
  /// The `live.isEmpty` branch is a last resort, not the normal path.
  /// On iOS 16.x `Activity.request` only succeeds while the app is in the
  /// foreground; from the background it throws
  /// `ActivityAuthorizationError.visibility` (background starts arrived in
  /// iOS 17, and only for apps with an active background session). So the
  /// fallback covers "the app is open and somehow has no activity", and is
  /// a logged no-op in exactly the case — driver inside another app — where
  /// an offer card would matter most. The activity has to be started when
  /// the shift starts, which is what `start()` is for.
  func offer(fare: String, perHour: String, miles: String, minutes: String) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      NSLog("[LiveActivity] offer refused: Live Activities are disabled for "
        + "this app in Settings — the ride card cannot be shown")
      return
    }
    let state = CruiseActivityAttributes.ContentState(
      status: "offer", since: Date(),
      fare: fare, perHour: perHour, miles: miles, minutes: minutes)
    enqueue {
      let live = Activity<CruiseActivityAttributes>.activities
      if live.isEmpty {
        // Nothing to update: the shift never started one, or iOS ended it.
        // Try anyway — it works when the app is foregrounded — and say so
        // in the log when it does not, instead of reporting a card the
        // driver cannot see.
        do {
          self.activity = try Activity.request(
            attributes: CruiseActivityAttributes(),
            content: .init(state: state, staleDate: nil))
        } catch {
          NSLog("[LiveActivity] offer: no running activity and request "
            + "failed (backgrounded on iOS 16, denied in Settings, or "
            + "over the system limit): %@", "\(error)")
        }
        return
      }
      for a in live {
        // staleDate: the offer expires on its own, and a card still
        // showing a ride the driver can no longer take is worse than no
        // card. iOS dims it at that point without another round trip.
        await a.update(.init(
          state: state, staleDate: Date().addingTimeInterval(45)))
      }
    }
  }

  func stop() {
    activity = nil
    enqueue {
      for a in Activity<CruiseActivityAttributes>.activities {
        await a.end(nil, dismissalPolicy: .immediate)
      }
    }
  }
}
#endif
