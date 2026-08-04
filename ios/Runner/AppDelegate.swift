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
      switch call.method {
      case "start":
        CruiseLiveActivityManager.shared.start(status: status)
        result(true)
      case "update":
        CruiseLiveActivityManager.shared.update(status: status)
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
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
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
        // Denied in Settings, backgrounded, or system limit — nothing to do.
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
