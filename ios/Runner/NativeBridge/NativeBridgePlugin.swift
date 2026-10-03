import Flutter
import UIKit
import Foundation
import LocalAuthentication
import Mobilebridge

/// Flutter 只给有限完整意图；钥匙、CA、slot、恢复 owner 和保存回调都由原生固定持有。
final class NativeBridgePlugin: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "org.harmoniavault.ios.native")
  private let mutex = NSLock()
  private let bundleID: String
  private let store: ProtectedDeviceStore
  private let directory: URL
  private let productFixture: ProductFixtureConfiguration?
  private let registry: MobilebridgeRecoveryRegistry
  private var busy = false
  private var epoch: UInt64 = 0
  private var context: LAContext?
  private var activeWorkflow: MobilebridgeVaultWorkflow?

  static func register(with registrar: FlutterPluginRegistrar) {
    guard let plugin = try? NativeBridgePlugin(configuration: ()) else { return }
    let channel = FlutterMethodChannel(name: "org.harmoniavault/native/v1", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    (UIApplication.shared.delegate as? AppDelegate)?.nativeBridge = plugin
  }

  init(configuration: Void) throws {
    guard let identifier = Bundle.main.bundleIdentifier else { throw NativeSecurityFailure("LOCKED") }
    productFixture = try ProductFixtureConfiguration.fromBundle()
    bundleID = identifier
    store = ProtectedDeviceStore(bundleIdentifier: identifier)
    directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("harmonia-system-v1", isDirectory: true)
    var error: NSError?
    guard let registry = MobilebridgeNewRecoveryRegistry(identifier, "workflow-state-v1.gcm", &error), error == nil else {
      throw NativeSecurityFailure("LOCKED")
    }
    self.registry = registry
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "fixtureConnectionInfo":
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      guard let productFixture else { result(FlutterMethodNotImplemented); return }
      result(productFixture.attestation)
    case "capabilities":
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      do {
        let state = SystemAuthentication.probe()
        result(["version": 1, "goCore": true, "systemStrongAuthentication": state == .ready,
          "protectedDeviceExists": try store.exists(), "realVaultReady": false,
          "softwareDeviceKeys": true, "systemAuthenticationState": state.rawValue,
          "appPinReady": false])
      } catch { reject(result, "PROTECTED_KEYS_UNAVAILABLE") }
    case "executePublic":
      guard let command = call.arguments as? String, !command.isEmpty, command.utf8.count <= 4096 else {
        reject(result, "INVALID_COMMAND"); return
      }
      run(result) { _ in try Self.go { MobilebridgeExecutePublic(command, &$0) } }
    case "workflowProfile":
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      run(result) { _ in try Self.go { MobilebridgeWorkflowProfile(&$0) } }
    case "createDevice":
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      authenticated(result, create: true, command: nil)
    case "executeUnlocked", "executeWorkflow":
      let workflow = call.method == "executeWorkflow"
      guard let command = call.arguments as? String, !command.isEmpty,
            command.utf8.count <= (workflow ? 32768 : 4096) else { reject(result, "INVALID_COMMAND"); return }
      authenticated(result, create: false, command: command, workflow: workflow)
    case "executeApproval", "executeEnrollment":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["command", "shortCode"],
            let command = args["command"] as? String, !command.isEmpty, command.utf8.count <= 32768,
            let bytes = args["shortCode"] as? FlutterStandardTypedData, bytes.data.count == 8,
            bytes.data.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { reject(result, "INVALID_COMMAND"); return }
      authenticated(result, create: false, command: command, workflow: true,
        shortCode: bytes.data, enrollment: call.method == "executeEnrollment")
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func acquire() throws -> UInt64 {
    mutex.lock(); defer { mutex.unlock() }
    guard !busy else { throw NativeSecurityFailure("BUSY") }
    busy = true
    return epoch
  }
  private func isActive(_ token: UInt64) -> Bool {
    mutex.lock(); defer { mutex.unlock() }; return token == epoch
  }
  private func finish(_ result: @escaping FlutterResult, token: UInt64, value: Any? = nil, error: Error? = nil) {
    DispatchQueue.main.async {
      self.mutex.lock()
      let active = token == self.epoch
      self.context?.invalidate(); self.context = nil; self.busy = false
      self.mutex.unlock()
      if !active { self.reject(result, "LOCKED") }
      else if let error { self.reject(result, (error as? NativeSecurityFailure)?.code ?? "GO_OR_KEYSTORE_REJECTED") }
      else { result(value) }
    }
  }
  private func reject(_ result: FlutterResult, _ code: String) {
    result(FlutterError(code: code, message: "原生安全操作未完成，未授予保险库访问。", details: nil))
  }
  static func go<T>(_ body: (inout NSError?) -> T) throws -> T {
    var error: NSError?
    let value = body(&error)
    if error != nil { throw NativeSecurityFailure("GO_OR_KEYSTORE_REJECTED") }
    return value
  }
  private func run(_ result: @escaping FlutterResult, operation: @escaping (UInt64) throws -> Any?) {
    do {
      let token = try acquire()
      worker.async {
        do { self.finish(result, token: token, value: try operation(token)) }
        catch { self.finish(result, token: token, error: error) }
      }
    } catch { reject(result, (error as? NativeSecurityFailure)?.code ?? "LOCKED") }
  }

  private func authenticated(_ result: @escaping FlutterResult, create: Bool, command: String?,
      workflow: Bool = false, shortCode: Data? = nil, enrollment: Bool = false) {
    // 包括 workflow / approval / enrollment，先限制完整意图的 endpoint，再开始认证。
    if workflow, let productFixture, !productFixture.acceptsWorkflow(command) {
      reject(result, "INVALID_COMMAND"); return
    }
    guard SystemAuthentication.probe() == .ready else { reject(result, "AUTH_UNAVAILABLE"); return }
    let token: UInt64
    do { token = try acquire() } catch { reject(result, "BUSY"); return }
    let authentication = SystemAuthentication.freshContext()
    mutex.lock(); context = authentication; mutex.unlock()
    // 创建前先认证；读取时直接执行受 ACL 保护的 SecItemCopyMatching。每意图只用一次新 context。
    if create {
      authentication.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "创建本机和弦设备钥匙") { success, error in
        guard success else { self.finish(result, token: token, error: SystemAuthentication.failure(error)); return }
        self.worker.async {
          self.perform(result, token: token, context: authentication, create: true, command: nil,
            workflow: false, shortCode: nil, enrollment: false)
        }
      }
    } else {
      worker.async {
        self.perform(result, token: token, context: authentication, create: false, command: command,
          workflow: workflow, shortCode: shortCode, enrollment: enrollment)
      }
    }
  }

  private func perform(_ result: @escaping FlutterResult, token: UInt64, context: LAContext, create: Bool,
      command: String?, workflow: Bool, shortCode: Data?, enrollment: Bool) {
    var material = Data()
    var code = shortCode ?? Data()
    var device: MobilebridgeDevice?
    defer { material.resetBytes(in: 0..<material.count); code.resetBytes(in: 0..<code.count); device?.close() }
    do {
      guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      if create {
        registry.clear()
        guard try !store.exists() else { throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE") }
        device = try Self.go { MobilebridgeNewDevice(&$0) }
        guard let device else { throw NativeSecurityFailure("GO_OR_KEYSTORE_REJECTED") }
        material = try device.exportProtectedMaterial()
        guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
        try store.create(material, context: context)
        try registry.resetForNewDevice()
        finish(result, token: token, value: try Self.go { device.execute("{\"version\":1,\"operation\":\"publicInfo\"}", error: &$0) })
        return
      }
      material = try store.open(context: context)
      guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      device = try Self.go { MobilebridgeImportProtectedMaterial(material, &$0) }
      material.resetBytes(in: 0..<material.count)
      guard let device, let command else { throw NativeSecurityFailure("INVALID_COMMAND") }
      if !workflow { finish(result, token: token, value: try Self.go { device.execute(command, error: &$0) }); return }
      guard let object = try JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any],
            let endpoint = object["endpoint"] as? String else { throw NativeSecurityFailure("INVALID_COMMAND") }
      let protected = ProtectedWorkflowStore(bundleIdentifier: bundleID, directory: directory) { self.isActive(token) }
      var state = try protected.load()
      defer { state.resetBytes(in: 0..<state.count) }
      let flow = try device.openWorkflow(endpoint, namespace: protected.namespace, sealed: state,
          additionalCA: productFixture?.publicCA ?? Data(), store: protected)
      mutex.lock(); activeWorkflow = flow; mutex.unlock()
      defer { mutex.lock(); activeWorkflow = nil; mutex.unlock(); flow.close() }
      guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      try flow.attach(registry)
      let response: String
      if shortCode != nil {
        response = try Self.go { error in
          enrollment ? flow.executeEnrollment(command, shortCode: code, error: &error) : flow.executeApproval(command, shortCode: code, error: &error)
        }
      } else { response = try Self.go { flow.execute(command, error: &$0) } }
      if flow.requiresDeviceDeletion() {
        registry.clear()
        try store.delete()
        try protected.delete()
      }
      finish(result, token: token, value: response)
    } catch {
      registry.clear()
      finish(result, token: token, error: error)
    }
  }

  func enterBackground() {
    mutex.lock(); epoch &+= 1; let oldContext = context; let oldFlow = activeWorkflow; mutex.unlock()
    oldContext?.invalidate(); oldFlow?.cancel(); registry.clear()
  }

  /// 仅解除原生背景遮罩，不执行业务；必须真实取回 ACL 钥匙，完成后立即清除。
  func unlockPrivacy(completion: @escaping (Bool) -> Void) {
    do {
      if try !store.exists() { completion(true); return }
      guard SystemAuthentication.probe() == .ready else { completion(false); return }
      let token = try acquire()
      let authentication = SystemAuthentication.freshContext()
      mutex.lock(); context = authentication; mutex.unlock()
      worker.async {
        var success = false
        do {
          var material = try self.store.open(context: authentication)
          material.resetBytes(in: 0..<material.count)
          success = self.isActive(token)
        } catch { success = false }
        DispatchQueue.main.async {
          self.mutex.lock(); self.context?.invalidate(); self.context = nil; self.busy = false; self.mutex.unlock()
          completion(success && self.isActive(token))
        }
      }
    } catch { completion(false) }
  }
}
