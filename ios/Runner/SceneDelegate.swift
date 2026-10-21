import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  // Driver referral Universal Links (/drive/{code}). Under the UIScene
  // lifecycle NSUserActivity is delivered HERE — a cold start carries it in
  // connectionOptions.userActivities, a warm one in scene(_:continue:) —
  // never at application(_:continue:) on the AppDelegate.
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for activity in connectionOptions.userActivities {
      guard activity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = activity.webpageURL else { continue }
      _ = AppDelegate.handleDriverReferralUrl(url)
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return }
    _ = AppDelegate.handleDriverReferralUrl(url)
  }
}
