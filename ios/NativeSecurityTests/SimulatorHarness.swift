// 仅独立合成安全测试应用；不编入 Runner，不提供产品认证绕过或诊断入口。
import UIKit
import Flutter
import Foundation
import LocalAuthentication
import Mobilebridge
import Darwin

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  var nativeBridge: NativeBridgePlugin?
  private var results: [[String: Any]] = []
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    return true
  }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "HarmoniaSecurity", sessionRole: session.role)
    configuration.delegateClass = HarnessSceneDelegate.self
    return configuration
  }
  private var started = false
  func beginTests() {
    guard !started else { return }
    started = true
    Task { @MainActor in await run() }
  }
  private func check(_ name: String, _ body: () throws -> Bool) {
    do { results.append(["name": name, "status": try body() ? "PASS" : "FAIL"]) }
    catch {
      let failure = error as NSError
      results.append(["name": name, "status": "FAIL", "errorDomain": failure.domain, "errorCode": failure.code, "nativeCode": (error as? NativeSecurityFailure)?.code ?? "UNSPECIFIED"])
    }
  }
  private func object(_ raw: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
      throw NativeSecurityFailure("TEST")
    }
    return value
  }
  private func invoke(_ method: String, _ arguments: Any? = nil) async -> Any? {
    await withCheckedContinuation { continuation in
      nativeBridge!.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { value in continuation.resume(returning: value) }
    }
  }
  @MainActor private func run() async {
    do { nativeBridge = try NativeBridgePlugin(configuration: ()) }
    catch { results.append(["name":"production-plugin-initialization", "status":"FAIL"]); finish(); return }
    check("LA-classification-never-downgrades-transient-errors") {
      let temporary: [LAError.Code] = [.userCancel, .appCancel, .systemCancel, .authenticationFailed,
        .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled, .invalidContext, .notInteractive]
      return temporary.allSatisfy {
        SystemAuthentication.classify(canEvaluate: false, error: NSError(domain: LAError.errorDomain, code: $0.rawValue)) == .temporarilyUnavailable
      } && SystemAuthentication.classify(canEvaluate: false, error: nil) == .unknown &&
        SystemAuthentication.classify(canEvaluate: false, error: NSError(domain: "other", code: LAError.Code.passcodeNotSet.rawValue)) == .unknown &&
        SystemAuthentication.classify(canEvaluate: false, error: NSError(domain: LAError.errorDomain, code: LAError.Code.passcodeNotSet.rawValue)) == .noDevicePasscode
    }
    let actualAuth = SystemAuthentication.probe()
    let caps = await invoke("capabilities") as? [String: Any]
    check("production-capabilities-no-fake-trust-or-PIN") {
      caps?["goCore"] as? Bool == true && caps?["realVaultReady"] as? Bool == false &&
      caps?["protectedDeviceExists"] as? Bool == false && caps?["appPinReady"] as? Bool == false &&
      caps?["systemStrongAuthentication"] as? Bool == (actualAuth == .ready)
    }
    let crypto = await invoke("executePublic", "{\"version\":1,\"operation\":\"selfTest\"}")
    check("actual-Go-BoringSSL-SPAKE2-Ed25519-HPKE-AEAD") {
      guard let raw = crypto as? String else { return false }
      let result = try object(raw)
      return ["sha256","ed25519","hpke","aead","spake2","tamperingRejected","confirmationGate","synthetic"].allSatisfy { result[$0] as? Bool == true } && result["realVaultReady"] as? Bool == false
    }
    let invalid = await invoke("executeApproval", ["command": "{}", "shortCode": FlutterStandardTypedData(bytes: Data("123".utf8))])
    check("invalid-short-code-rejected-before-authentication") { (invalid as? FlutterError)?.code == "INVALID_COMMAND" }
    if actualAuth != .ready {
      let create = await invoke("createDevice")
      check("actual-unavailable-system-auth-cannot-create-device") { (create as? FlutterError)?.code == "AUTH_UNAVAILABLE" }
      let after = await invoke("capabilities") as? [String: Any]
      check("failed-auth-leaves-protected-device-absent") { after?["protectedDeviceExists"] as? Bool == false }
    } else {
      results.append(["name":"actual-unavailable-system-auth-cannot-create-device", "status":"UNRUN", "reason":"simulator-reports-system-auth-ready"])
    }
    check("Keychain-missing-slot-never-returns-material") {
      let slot = ProtectedDeviceStore(bundleIdentifier: Bundle.main.bundleIdentifier! + ".missing")
      guard try !slot.exists() else { return false }
      let context = SystemAuthentication.freshContext(); context.interactionNotAllowed = true
      defer { context.invalidate() }
      do { _ = try slot.open(context: context); return false } catch { return try !slot.exists() }
    }
    check("durable-encrypted-state-reopen-invalid-save-and-cancellation") {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("state-" + UUID().uuidString)
      var active = true
      let store = ProtectedWorkflowStore(bundleIdentifier: Bundle.main.bundleIdentifier!, directory: directory) { active }
      let packet = Data("HARMST01".utf8) + Data(repeating: 0x5a, count: 64)
      try store.saveSealed(packet)
      let reopened = ProtectedWorkflowStore(bundleIdentifier: Bundle.main.bundleIdentifier!, directory: directory) { true }
      guard try reopened.load() == packet else { return false }
      do { try store.saveSealed(Data("malformed".utf8)); return false } catch {}
      guard try reopened.load() == packet else { return false }
      active = false
      do { try store.saveSealed(Data("HARMST01".utf8) + Data(repeating: 0x77, count: 64)); return false } catch {}
      guard try reopened.load() == packet else { return false }
      try reopened.delete()
      return try reopened.load().isEmpty
    }
    check("actual-Go-software-device-and-view-remain-untrusted") {
      guard let device = try NativeBridgePlugin.go({ MobilebridgeNewDevice(&$0) }) else { return false }
      defer { device.close() }
      let info = try object(NativeBridgePlugin.go { device.execute("{\"version\":1,\"operation\":\"publicInfo\"}", error: &$0) })
      guard info["trusted"] as? Bool == false else { return false }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-" + UUID().uuidString)
      let store = ProtectedWorkflowStore(bundleIdentifier: Bundle.main.bundleIdentifier!, directory: directory) { true }
      let flow = try device.openWorkflow("https://synthetic.invalid", namespace: store.namespace, sealed: Data(), additionalCA: Data(), store: store)
      defer { flow.close() }
      let result = try object(NativeBridgePlugin.go { flow.execute("{\"version\":1,\"operation\":\"view\",\"endpoint\":\"https://synthetic.invalid\"}", error: &$0) })
      return result["ok"] as? Bool == false && result["code"] as? String == "NOT_TRUSTED"
    }
    check("strict-Go-command-parser-rejects-duplicate-fields") {
      do {
        _ = try NativeBridgePlugin.go { MobilebridgeExecutePublic("{\"version\":1,\"operation\":\"selfTest\",\"operation\":\"capabilities\"}", &$0) }
        return false
      } catch { return true }
    }
    if let accountURL = Bundle.main.url(forResource: "HarmoniaSyntheticAccount", withExtension: "json"),
       let caURL = Bundle.main.url(forResource: "HarmoniaSyntheticCA", withExtension: "pem") {
      check("actual-iOS-Go-HTTPS-account-login-is-not-device-trust") {
        let account = try JSONSerialization.jsonObject(with: Data(contentsOf: accountURL)) as! [String:String]
        let endpoint = account["endpoint"]!
        guard endpoint == "https://127.0.0.1:5593", account["email"]!.hasSuffix(".invalid") else { return false }
        let ca = try Data(contentsOf: caURL)
        guard let device = try NativeBridgePlugin.go({ MobilebridgeNewDevice(&$0) }) else { return false }
        defer { device.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-" + UUID().uuidString)
        let store = ProtectedWorkflowStore(bundleIdentifier: Bundle.main.bundleIdentifier!, directory: directory) { true }
        func command(_ operation: String, password: String? = nil) throws -> String {
          var fields: [String:Any] = ["version":1,"operation":operation,"endpoint":endpoint]
          if let password { fields["email"] = account["email"]!; fields["password"] = password }
          return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        }
        // 未加入本次CA时必须失败，绝不设置跳过证书或hostname验证。
        let untrustedTLS = try device.openWorkflow(endpoint, namespace: store.namespace, sealed: Data(), additionalCA: Data(), store: store)
        let login = try command("loginAccount", password: account["password"]!)
        let deniedTLS = try object(NativeBridgePlugin.go { untrustedTLS.execute(login, error: &$0) })
        untrustedTLS.close()
        guard deniedTLS["ok"] as? Bool == false else { return false }
        let flow = try device.openWorkflow(endpoint, namespace: store.namespace, sealed: Data(), additionalCA: ca, store: store)
        defer { flow.close() }
        let authenticated = try object(NativeBridgePlugin.go { flow.execute(login, error: &$0) })
        guard authenticated["ok"] as? Bool == true,
          let data = authenticated["data"] as? [String:Bool], data == ["authenticated":true,"trustedDevice":false] else { return false }
        let viewCommand = try command("view")
        let view = try object(NativeBridgePlugin.go { flow.execute(viewCommand, error: &$0) })
        guard view["ok"] as? Bool == false, view["code"] as? String == "NOT_TRUSTED" else { return false }
        let wrongCommand = try command("loginAccount", password: "incorrect-synthetic-password")
        let wrong = try object(NativeBridgePlugin.go { flow.execute(wrongCommand, error: &$0) })
        let persisted = try store.load()
        return wrong["ok"] as? Bool == false && persisted.isEmpty
      }
    } else {
      results.append(["name":"actual-iOS-Go-HTTPS-account-login-is-not-device-trust", "status":"UNRUN", "reason":"no-independent-native-fixture-resources"])
    }
    if actualAuth == .noDevicePasscode {
      check("actual-Keychain-MAC-Go-Argon2-PIN-durable-limiter-and-no-trust") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pin-" + UUID().uuidString)
        let system = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("harmonia-system-v1")
        let slot = "test-" + UUID().uuidString.lowercased()
        let instance = try LocalPINSlot(package: Bundle.main.bundleIdentifier!, slot: slot, endpoint: "https://synthetic.invalid", directory: directory, systemDirectory: system)
        let pin = Data("184729".utf8)
        try instance.create(pin: pin, reentry: pin)
        defer { try? instance.forget() }
        let command = Data("{\"version\":1,\"operation\":\"view\",\"endpoint\":\"https://synthetic.invalid\"}".utf8)
        let correct = try object(instance.execute(pin: pin, completeIntent: command))
        guard correct["ok"] as? Bool == false, correct["code"] as? String == "NOT_TRUSTED" else { return false }
        let first = try instance.attemptMetadata()
        guard first.total == 1, first.failures == 0 else { return false }
        let reopened = try LocalPINSlot(package: Bundle.main.bundleIdentifier!, slot: slot, endpoint: "https://synthetic.invalid", directory: directory, systemDirectory: system)
        do { _ = try reopened.execute(pin: Data("927481".utf8), completeIntent: command); return false } catch {}
        let failed = try instance.attemptMetadata()
        guard failed.total == 2, failed.failures == 1, failed.revision > first.revision else { return false }
        let fd = Darwin.open(directory.appendingPathComponent("operation.lock").path, O_RDWR)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        var busyRejected = false
        do { _ = try reopened.execute(pin: pin, completeIntent: command) }
        catch let failure as NativeSecurityFailure { busyRejected = failure.code == "BUSY" }
        catch {}
        _ = flock(fd, LOCK_UN); Darwin.close(fd)
        guard busyRejected, try instance.attemptMetadata().total == 2 else { return false }
        // 只破坏自己的合成packet；MAC错误不得被解释成新slot或重置limiter。
        let file = directory.appendingPathComponent("pin-state-v1.packet")
        var corrupted = try Data(contentsOf: file); corrupted[corrupted.count / 2] ^= 1
        try corrupted.write(to: file)
        do { _ = try reopened.execute(pin: pin, completeIntent: command); return false } catch {}
        do { try reopened.create(pin: pin, reentry: pin); return false } catch {}
        try reopened.forget()
        try reopened.create(pin: pin, reentry: pin)
        let reset = try reopened.attemptMetadata()
        guard reset.total == 0, reset.failures == 0, reset.recordHash != first.recordHash else { return false }
        let again = try object(reopened.execute(pin: pin, completeIntent: command))
        return again["ok"] as? Bool == false && again["code"] as? String == "NOT_TRUSTED"
      }
    } else {
      results.append(["name":"actual-Keychain-MAC-Go-Argon2-PIN-durable-limiter-and-no-trust", "status":"UNRUN", "reason":"actual-LA-did-not-report-passcodeNotSet"])
    }
    results += LocalPINSlot.runStorageComponentTests(package: Bundle.main.bundleIdentifier!, root: FileManager.default.temporaryDirectory.appendingPathComponent("pin-components-" + UUID().uuidString))
    if actualAuth == .ready {
      // 使用真实生产认证入口；有界触发同一背景取消，不注入LA结果，也不模拟通过。
      let cancellation = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 250_000_000)
        if !Task.isCancelled { nativeBridge?.enterBackground() }
      }
      let outcome = await invoke("createDevice")
      cancellation.cancel()
      check("actual-system-auth-production-entry-bounded-no-trust") {
        let own = ProtectedDeviceStore(bundleIdentifier: Bundle.main.bundleIdentifier!)
        if let error = outcome as? FlutterError {
          guard ["LOCKED", "AUTH_CANCELLED", "AUTH_FAILED", "AUTH_UNAVAILABLE", "PROTECTED_KEYS_UNAVAILABLE"].contains(error.code) else { return false }
          if try own.exists() { try own.delete() }
          return try !own.exists()
        }
        // Simulator如自行完成认证，仅记录真实SDK代码完成；仍不等于真机因素/硬件通过。
        guard let raw = outcome as? String, try object(raw)["trusted"] as? Bool == false, try own.exists() else { return false }
        try own.delete()
        return try !own.exists()
      }
      results[results.count - 1]["scope"] = "simulator-real-SDK-call-not-real-device-auth-proof"
      results[results.count - 1]["outcome"] = (outcome as? FlutterError)?.code ?? "simulator-SDK-completed-untrusted"
    }
    results.append(["name":"real-device-passcode-biometry-and-hardware-security", "status":"UNRUN", "reason":"simulator-does-not-prove-real-device-security"])
    finish(authState: actualAuth.rawValue)
  }
  private func finish(authState: String = "unknown") {
    let runID = (try? String(contentsOf: Bundle.main.url(forResource: "HarmoniaHarnessRunID", withExtension: "txt")!, encoding: .utf8)) ?? "missing"
    let summary: [String: Any] = ["runId": runID, "profile":"harmonia/ios-simulator-security/v1", "synthetic":true,
      "realVaultReady":false, "systemAuthenticationState":authState,
      "results":results, "pass":results.filter { $0["status"] as? String == "PASS" }.count,
      "fail":results.filter { $0["status"] as? String == "FAIL" }.count]
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("native-result.json"), options: .atomic)
      print("HARMONIA_IOS_SECURITY_TESTS_COMPLETE")
    } catch { print("HARMONIA_IOS_SECURITY_REPORT_WRITE_FAILED") }
  }
}

@objc(HarmoniaHarnessSceneDelegate)
final class HarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: scene)
    let view = UIViewController(); view.view.backgroundColor = .systemBackground
    window?.rootViewController = view; window?.makeKeyAndVisible()
  }
  func sceneDidBecomeActive(_ scene: UIScene) { (UIApplication.shared.delegate as? AppDelegate)?.beginTests() }
}
