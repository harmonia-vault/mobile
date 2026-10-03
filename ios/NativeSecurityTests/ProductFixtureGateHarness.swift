// 仅独立 Simulator 配置门槛测试。不触发 LA，不读取设备钥匙或网络。
import UIKit

@main final class ProductFixtureGateHarness: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    true
  }
}

@objc(ProductFixtureGateScene) final class ProductFixtureGateScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    var actual = "unexpected-error"
    do { actual = try ProductFixtureConfiguration.fromBundle() == nil ? "disabled" : "enabled" }
    catch let error as NativeSecurityFailure { actual = error.code == "FIXTURE_CONFIGURATION" ? "rejected" : "unexpected-error" }
    catch {}
    let expected = Bundle.main.object(forInfoDictionaryKey: "FixtureGateExpected") as? String ?? "invalid"
    let passed = actual == expected
    let result: [String: Any] = ["version": 1, "test": "fromBundle", "expected": expected,
      "actual": actual, "result": passed ? "PASS" : "FAIL", "authenticationInvoked": false,
      "runID": Bundle.main.object(forInfoDictionaryKey: "FixtureGateRunID") as? String ?? "missing"]
    do {
      let target = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("fixture-gate-result.json")
      try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: target, options: .atomic)
    } catch { return }
    window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    let label = UILabel(frame: CGRect(x: 24, y: 100, width: 350, height: 90))
    label.text = passed ? "FIXTURE GATE PASS" : "FIXTURE GATE FAIL"
    controller.view.addSubview(label)
    window?.rootViewController = controller
    window?.makeKeyAndVisible()
  }
}
