import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // MARK: - 防息屏
  //
  // 任务跑在手机端引擎里时，屏幕一旦自动熄灭，系统会把 App 推到后台并挂起，
  // 正在执行的会话就被打断。所以 App 真正在前台时保持常亮。
  //
  // 这里必须是 SceneDelegate：工程启用了 UIScene（Info.plist 里有
  // UIApplicationSceneManifest），此时 AppDelegate 的
  // applicationDidBecomeActive / applicationWillResignActive 不会被调用，
  // 写在那边等于没有。生命周期以 scene 为准。
  //
  // `isIdleTimerDisabled` 只能在主线程设置，这几个回调本来就在主线程。

  /// 用户是否允许常亮；默认开。设置页要关掉时可以改这里。
  static var keepAwakeAllowed = true

  /// 记下最近一次是不是我们把它点亮了，避免反复写同一个值。
  private static var awake = false

  static func applyKeepAwake(_ active: Bool) {
    let wanted = active && keepAwakeAllowed
    guard awake != wanted else { return }
    awake = wanted
    UIApplication.shared.isIdleTimerDisabled = wanted
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    StartupWatch.shared.arm((scene as? UIWindowScene)?.windows.first)
    SceneDelegate.applyKeepAwake(true)
  }

  /// 退到后台（或被来电、下拉通知中心遮住）时立刻恢复系统默认，不白耗电。
  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    SceneDelegate.applyKeepAwake(false)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    super.sceneDidDisconnect(scene)
    SceneDelegate.applyKeepAwake(false)
  }
}
