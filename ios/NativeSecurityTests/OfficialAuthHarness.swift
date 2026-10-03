// 仅独立 Simulator 测试入口。生产源码字节固定于 public 9e0a00b。
// 认证仅由真实 LocalAuthentication / Keychain SDK 和 Simulator 官方界面完成。
import UIKit
import Flutter
import Foundation
import LocalAuthentication
import Security

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var nativeBridge: NativeBridgePlugin?
  var label: UILabel?
  private var started = false
  private var report: [String: Any] = ["profile":"harmonia/ios-official-simulator-auth/v1", "synthetic":true,
    "scope":"official-Simulator-SDK-only-not-physical-device", "realVaultReady":false, "appPinReady":false]
  private var results: [[String: Any]] = []
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let c = UISceneConfiguration(name:"HarmoniaOfficialAuth",sessionRole:session.role);c.delegateClass=OfficialAuthScene.self;return c
  }
  func begin() {
    guard !started else {return};started=true
    report["runId"] = try? String(contentsOf:Bundle.main.url(forResource:"HarmoniaHarnessRunID",withExtension:"txt")!,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
    Task { @MainActor in await run() }
  }
  private func persist(_ phase: String) {
    report["phase"]=phase;report["results"]=results
    report["updatedUTC"]=ISO8601DateFormatter().string(from:Date())
    label?.text="Harmonia 合成认证测试\n"+phase+"\n仅 Simulator SDK，非真机认证证据"
    let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    do {try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:dir.appendingPathComponent("official-auth-result.json"),options:.atomic)} catch {print("HARMONIA_AUTH_REPORT_WRITE_FAILED")}
  }
  private func invoke(_ method:String,_ arguments:Any?=nil) async -> Any? {
    await withCheckedContinuation { continuation in nativeBridge!.handle(FlutterMethodCall(methodName:method,arguments:arguments)) { continuation.resume(returning:$0) } }
  }
  private func bounded(_ method:String,_ arguments:Any?=nil) async -> Any? {
    let timeout=Task { @MainActor in
      try? await Task.sleep(nanoseconds:90_000_000_000)
      if !Task.isCancelled { report["deadlineCancellation"]=true;nativeBridge?.enterBackground() }
    }
    let outcome=await invoke(method,arguments);timeout.cancel();return outcome
  }
  private func info(_ value:Any?) -> [String:Any]? {
    guard let raw=value as? String,let o=try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else{return nil};return o
  }
  private func protectedMetadataStatus() -> Int32 {
    let context=SystemAuthentication.freshContext();context.interactionNotAllowed=true;defer{context.invalidate()}
    return SecItemCopyMatching([kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:Bundle.main.bundleIdentifier!+".harmonia.system-device.v1",
      kSecAttrAccount as String:"device-material-v1",kSecAttrSynchronizable as String:false,
      kSecReturnAttributes as String:true,kSecUseAuthenticationContext as String:context] as CFDictionary,nil)
  }
  @MainActor private func run() async {
    let store=ProtectedDeviceStore(bundleIdentifier:Bundle.main.bundleIdentifier!)
    do {
      guard try !store.exists() else {report["blockingReason"]="own-slot-already-exists-no-reuse";persist("BLOCKED");return}
      nativeBridge=try NativeBridgePlugin(configuration:())
    } catch {report["blockingReason"]=(error as? NativeSecurityFailure)?.code ?? "INITIALIZATION";persist("BLOCKED");return}
    report["authenticationState"]=SystemAuthentication.probe().rawValue
    let caps=await invoke("capabilities") as? [String:Any]
    report["initialCapabilities"]=caps
    guard caps?["systemStrongAuthentication"] as? Bool == true else {persist("UNRUN-system-auth-unavailable");return}
    persist("AWAITING-official-device-auth-create")
    let create=await bounded("createDevice")
    guard let created=info(create),created["trusted"] as? Bool == false,(try? store.exists()) == true else {
      results.append(["name":"production-create-and-ACL-readback","status":"FAIL","code":(create as? FlutterError)?.code ?? "UNEXPECTED_RESULT","keychainAttributeStatus":protectedMetadataStatus()])
      if (try? store.exists()) == true { do {try store.delete();report["ownCleanupVerified"] = try !store.exists()}catch{report["ownCleanupVerified"]=false} }
      persist("COMPLETE-with-failure");return
    }
    results.append(["name":"production-create-and-ACL-readback","status":"PASS","trusted":false])
    persist("AWAITING-fresh-context-ACL-read")
    let reopened=await bounded("executeUnlocked","{\"version\":1,\"operation\":\"publicInfo\"}")
    if let opened=info(reopened),opened["trusted"] as? Bool == false,opened["deviceId"] as? String == created["deviceId"] as? String {
      results.append(["name":"production-fresh-context-ACL-key-read-and-Go-import","status":"PASS","trusted":false])
    } else {results.append(["name":"production-fresh-context-ACL-key-read-and-Go-import","status":"FAIL","code":(reopened as? FlutterError)?.code ?? "UNEXPECTED_RESULT"])}
    do {try store.delete();report["ownCleanupVerified"]=try !store.exists()}catch{report["ownCleanupVerified"]=false}
    results.append(["name":"physical-device-passcode-biometric-hardware","status":"UNRUN","reason":"Simulator-cannot-prove-physical-factor-or-hardware"])
    persist("COMPLETE")
  }
}
@objc(HarmoniaOfficialAuthScene)
final class OfficialAuthScene:UIResponder,UIWindowSceneDelegate {
 var window:UIWindow?
 func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
  guard let s=scene as? UIWindowScene else{return};window=UIWindow(windowScene:s)
  let vc=UIViewController();vc.view.backgroundColor = .systemBackground
  let label=UILabel(frame:CGRect(x:20,y:160,width:340,height:220));label.numberOfLines=0;label.text="Harmonia 合成认证测试";label.textColor = .label;vc.view.addSubview(label)
  (UIApplication.shared.delegate as? AppDelegate)?.label=label;window?.rootViewController=vc;window?.makeKeyAndVisible()
 }
 func sceneDidBecomeActive(_ scene:UIScene) {(UIApplication.shared.delegate as? AppDelegate)?.begin()}
}
