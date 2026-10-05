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
  private var busy = false
  private var epoch: UInt64 = 0
  private var context: LAContext?
  private var activeWorkflow: MobilebridgeVaultWorkflow?
  private var dagRegistry: MobilebridgeNativeDAGRegistry?
  private var dagEndpoint: String?
  private var resetOwner: MobilebridgeNativeAccountReset?
  private var resetEndpoint: String?
  private var resetMail: MobilebridgeNativeAccountResetMail?
  private var drains = 0

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
        let pinExists = try store.hasPINArtifacts()
        result(["version": 1, "goCore": true, "systemStrongAuthentication": state == .ready && !pinExists,
          "protectedDeviceExists": try store.exists(), "realVaultReady": false,
          "protectedStateExists": try pinExists || store.exists() || workflowStore { true }.exists(),
          "nativePublicAccount": true, "nativeDAGOwnerCancellation": true,
          "nativeDAGBusiness": true, "nativeDAGEnvironment": true,
          "nativeAccountReset": true, "nativeAccountResetEmailRequest": true,
          "softwareDeviceKeys": true, "systemAuthenticationState": state.rawValue,
          "appPinReady": false])
      } catch { reject(result, "PROTECTED_KEYS_UNAVAILABLE") }
    case "executePublic":
      guard let command = call.arguments as? String, !command.isEmpty, command.utf8.count <= 4096 else {
        reject(result, "INVALID_COMMAND"); return
      }
      run(result) { _ in try Self.go { MobilebridgeExecutePublic(command, &$0) } }
    case "executeAccount":
      guard let command = call.arguments as? String, !command.isEmpty, command.utf8.count <= 32768,
            acceptsEndpoint(command: command) else { reject(result, "INVALID_COMMAND"); return }
      run(result) { _ in try Self.go { MobilebridgeExecuteAccount(command, self.productFixture?.publicCA ?? Data(), &$0) } }
    case "dagWorkflowProfile", "dagBusinessProfile", "dagEnvironmentProfile":
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      run(result) { _ in
        try Self.go {
          switch call.method {
          case "dagBusinessProfile": return MobilebridgeDAGBusinessProfile(&$0)
          case "dagEnvironmentProfile": return MobilebridgeDAGEnvironmentProfile(&$0)
          default: return MobilebridgeDAGWorkflowProfile(&$0)
          }
        }
      }
    case "executeDAGRecovery", "executeDAGBusiness", "executeDAGEnvironment":
      handleDAG(call, result: result)
    case "requestAccountResetEmail", "beginAccountReset", "beginAccountResetQueryOnly",
         "queryAccountReset", "prepareAccountReset", "completeAccountReset", "cancelAccountReset":
      handleAccountReset(call, result: result)
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

  private func acquire(allowReset: Bool = false) throws -> UInt64 {
    mutex.lock(); defer { mutex.unlock() }
    guard !busy, drains == 0, allowReset || resetOwner == nil else { throw NativeSecurityFailure("BUSY") }
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
    if let error {
      let allowed = ["EMAIL_CODE_INVALID", "EMAIL_CODE_EXPIRED", "EMAIL_CODE_EXHAUSTED"]
      throw NativeSecurityFailure(allowed.contains(error.localizedDescription) ? error.localizedDescription : "GO_OR_KEYSTORE_REJECTED")
    }
    return value
  }
  private func run(_ result: @escaping FlutterResult, allowReset: Bool = false, operation: @escaping (UInt64) throws -> Any?) {
    do {
      let token = try acquire(allowReset: allowReset)
      worker.async {
        do {
          guard self.isActive(token) else { throw NativeSecurityFailure("LOCKED") }
          self.finish(result, token: token, value: try operation(token))
        }
        catch { self.finish(result, token: token, error: error) }
      }
    } catch { reject(result, (error as? NativeSecurityFailure)?.code ?? "LOCKED") }
  }

  private func authenticated(_ result: @escaping FlutterResult, create: Bool, command: String?,
      workflow: Bool = false, shortCode: Data? = nil, enrollment: Bool = false, dagMethod: String? = nil) {
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
            workflow: false, shortCode: nil, enrollment: false, dagMethod: nil)
        }
      }
    } else {
      worker.async {
        self.perform(result, token: token, context: authentication, create: false, command: command,
          workflow: workflow, shortCode: shortCode, enrollment: enrollment, dagMethod: dagMethod)
      }
    }
  }

  private func perform(_ result: @escaping FlutterResult, token: UInt64, context: LAContext, create: Bool,
      command: String?, workflow: Bool, shortCode: Data?, enrollment: Bool, dagMethod: String?) {
    do {
      let response = try performUnlocked(token: token, context: context, create: create,
        command: command, workflow: workflow, shortCode: shortCode, enrollment: enrollment, dagMethod: dagMethod)
      // performUnlocked 返回前已关闭 Workflow、设备和固定槽锁。
      finish(result, token: token, value: response)
    } catch {
      closeDAGRegistry()
      finish(result, token: token, error: error)
    }
  }

  private func performUnlocked(token: UInt64, context: LAContext, create: Bool,
      command: String?, workflow: Bool, shortCode: Data?, enrollment: Bool, dagMethod: String?) throws -> String {
    var material = Data()
    var code = shortCode ?? Data()
    var device: MobilebridgeDevice?
    defer { material.resetBytes(in: 0..<material.count); code.resetBytes(in: 0..<code.count); device?.close() }
    guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
    let protected = workflowStore { self.isActive(token) }
    try protected.acquireSlot()
    defer { protected.closeSlot() }
    guard try !store.hasPINArtifacts() else { throw NativeSecurityFailure("LOCAL_PROTECTION_STATE") }
    if create {
      closeDAGRegistry()
      guard try !store.exists(), try !protected.exists() else { throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE") }
      device = try Self.go { MobilebridgeNewDevice(&$0) }
      guard let device else { throw NativeSecurityFailure("GO_OR_KEYSTORE_REJECTED") }
      material = try device.exportProtectedMaterial()
      guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      try store.create(material, context: context)
      closeDAGRegistry()
      return try Self.go { device.execute("{\"version\":1,\"operation\":\"publicInfo\"}", error: &$0) }
    }
    material = try store.open(context: context)
    guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
    device = try Self.go { MobilebridgeImportProtectedMaterial(material, &$0) }
    material.resetBytes(in: 0..<material.count)
    guard let device, let command else { throw NativeSecurityFailure("INVALID_COMMAND") }
    if !workflow { return try Self.go { device.execute(command, error: &$0) } }
    guard let object = try JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any],
          let endpoint = object["endpoint"] as? String else { throw NativeSecurityFailure("INVALID_COMMAND") }
    var state = try protected.load()
    defer { state.resetBytes(in: 0..<state.count) }
    let flow = try device.openAtomicWorkflow(endpoint, namespace: protected.namespace, sealed: state,
        additionalCA: productFixture?.publicCA ?? Data(), store: protected)
    mutex.lock(); activeWorkflow = flow; mutex.unlock()
    defer { mutex.lock(); activeWorkflow = nil; mutex.unlock(); flow.close() }
    guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
    if dagMethod == "executeDAGRecovery" {
      try flow.attach(recoveryRegistry(endpoint: endpoint, token: token))
    } else if dagMethod == nil {
      closeDAGRegistry()
    }
    let response: String
    if let dagMethod {
      response = try Self.go { error in
        switch dagMethod {
        case "executeDAGBusiness": return flow.executeDAGBusiness(command, value: code, error: &error)
        case "executeDAGEnvironment": return flow.executeDAGEnvironment(command, name: code, error: &error)
        default: return flow.executeDAGRecovery(command, completeCode: code, error: &error)
        }
      }
    } else if shortCode != nil {
      response = try Self.go { error in
        enrollment ? flow.executeEnrollment(command, shortCode: code, error: &error) : flow.executeApproval(command, shortCode: code, error: &error)
      }
    } else { response = try Self.go { flow.execute(command, error: &$0) } }
    if flow.requiresDeviceDeletion() {
      closeDAGRegistry()
      try store.delete()
      try protected.delete()
    }
    return response
  }

  func enterBackground() {
    retireAccess()
  }

  private func workflowStore(_ active: @escaping () -> Bool) -> ProtectedWorkflowStore {
    ProtectedWorkflowStore(bundleIdentifier: bundleID, directory: directory, isActive: active)
  }

  private func acceptsEndpoint(command: String) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any],
          let endpoint = value["endpoint"] as? String else { return false }
    return acceptsEndpoint(endpoint)
  }
  private func acceptsEndpoint(_ endpoint: String) -> Bool {
    guard let url = URLComponents(string: endpoint), url.scheme == "https",
          url.host?.isEmpty == false, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil else { return false }
    return productFixture == nil || endpoint == ProductFixtureConfiguration.endpoint
  }

  private func recoveryRegistry(endpoint: String, token: UInt64) throws -> MobilebridgeNativeDAGRegistry {
    mutex.lock(); defer { mutex.unlock() }
    guard token == epoch, token < UInt64(Int64.max) else { throw NativeSecurityFailure("LOCKED") }
    if let dagRegistry {
      guard dagEndpoint == endpoint else { throw NativeSecurityFailure("INVALID_COMMAND") }
      return dagRegistry
    }
    guard let created = try Self.go({ MobilebridgeNewNativeDAGRegistry(bundleID, "workflow-state-v1.gcm", Int64(token) + 1, &$0) }) else {
      throw NativeSecurityFailure("LOCKED")
    }
    dagRegistry = created; dagEndpoint = endpoint
    return created
  }
  private func closeDAGRegistry() {
    mutex.lock(); let old = dagRegistry; dagRegistry = nil; dagEndpoint = nil; mutex.unlock()
    old?.invalidate(); old?.close()
  }

  private func handleDAG(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let inputKey: String
    switch call.method {
    case "executeDAGBusiness": inputKey = "value"
    case "executeDAGEnvironment": inputKey = "name"
    default: inputKey = "completeCode"
    }
    guard let args = call.arguments as? [String: Any], Set(args.keys) == ["command", inputKey],
          let command = args["command"] as? String, command.utf8.count <= 32768,
          let bytes = args[inputKey] as? FlutterStandardTypedData, bytes.data.count <= 65536,
          acceptsEndpoint(command: command) else { reject(result, "INVALID_COMMAND"); return }
    do {
      _ = try Self.go { error in
        switch call.method {
        case "executeDAGBusiness": return MobilebridgeValidateDAGBusinessCommand(command, &error)
        case "executeDAGEnvironment": return MobilebridgeValidateDAGEnvironmentCommand(command, &error)
        default: return MobilebridgeValidateDAGRecoveryCommand(command, Int64(bytes.data.count), &error)
        }
      }
      guard let object = try JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any] else {
        throw NativeSecurityFailure("INVALID_COMMAND")
      }
      if object["operation"] as? String == "cancelDAGRecoveryOwner" {
        mutex.lock(); let currentEndpoint = dagEndpoint; mutex.unlock()
        guard currentEndpoint == nil || currentEndpoint == object["endpoint"] as? String else {
          throw NativeSecurityFailure("INVALID_COMMAND")
        }
        retireAccess {
          result("{\"version\":1,\"operation\":\"cancelDAGRecoveryOwner\",\"localOwnerClosed\":true,\"journalPreserved\":true,\"trustedDevice\":false}")
        }
        return
      }
      authenticated(result, create: false, command: command, workflow: true,
        shortCode: bytes.data, dagMethod: call.method)
    } catch { reject(result, "INVALID_COMMAND") }
  }

  // 取消先撤销在途操作，再等待同一串行 worker 关闭所有对象，最后回复 Dart。
  private func retireAccess(completion: (() -> Void)? = nil) {
    mutex.lock()
    epoch &+= 1; drains += 1
    let oldContext = context, oldFlow = activeWorkflow, oldDAG = dagRegistry
    let oldReset = resetOwner, oldMail = resetMail
    dagRegistry = nil; dagEndpoint = nil; resetOwner = nil; resetEndpoint = nil; resetMail = nil
    mutex.unlock()
    oldContext?.invalidate(); oldFlow?.invalidate(); oldDAG?.invalidate()
    oldReset?.close(); oldMail?.close()
    worker.async {
      oldDAG?.close()
      DispatchQueue.main.async {
        self.mutex.lock(); self.drains -= 1; self.mutex.unlock()
        completion?()
      }
    }
  }

  private func accountReset(token: UInt64) throws -> (MobilebridgeNativeAccountReset, String) {
    mutex.lock(); defer { mutex.unlock() }
    guard token == epoch, let resetOwner, let resetEndpoint else { throw NativeSecurityFailure("LOCKED") }
    return (resetOwner, resetEndpoint)
  }

  private func handleAccountReset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancelAccountReset" {
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      retireAccess { result(nil) }; return
    }
    if ["queryAccountReset", "completeAccountReset"].contains(call.method) {
      guard call.arguments == nil else { reject(result, "INVALID_COMMAND"); return }
      run(result, allowReset: true) { token in
        if call.method == "completeAccountReset" { return try self.completeAccountReset(token: token) }
        let owner = try self.accountReset(token: token).0
        return try Self.go { owner.query(&$0) }
      }
      return
    }
    let preparing = call.method == "prepareAccountReset"
    let mail = call.method == "requestAccountResetEmail"
    let key: String
    let inputLimit: Int
    switch call.method {
    case "prepareAccountReset": key = "password"; inputLimit = 16384
    case "requestAccountResetEmail": key = "email"; inputLimit = 320
    default: key = "proof"; inputLimit = 4096
    }
    let expected: Set<String> = preparing ? ["password", "confirmation"] : ["endpoint", key]
    guard let args = call.arguments as? [String: Any], Set(args.keys) == expected,
          let typed = args[key] as? FlutterStandardTypedData,
          !typed.data.isEmpty, typed.data.count <= inputLimit,
          String(data: typed.data, encoding: .utf8) != nil else { reject(result, "INVALID_COMMAND"); return }
    if preparing {
      guard args["confirmation"] as? String == "DELETE_OLD_VAULT" else { reject(result, "INVALID_COMMAND"); return }
    } else {
      guard let endpoint = args["endpoint"] as? String, acceptsEndpoint(endpoint) else { reject(result, "INVALID_COMMAND"); return }
      if !mail {
        guard let proof = try? JSONSerialization.jsonObject(with: typed.data) as? [String: Any],
              Set(proof.keys) == ["email", "code"], let email = proof["email"] as? String, !email.isEmpty,
              let code = proof["code"] as? String, code.utf8.count == 6,
              code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
          reject(result, "INVALID_COMMAND"); return
        }
      }
    }
    run(result, allowReset: preparing) { token in
      var input = typed.data
      defer { input.resetBytes(in: 0..<input.count) }
      if preparing {
        try self.accountReset(token: token).0.prepare(input, confirmation: "DELETE_OLD_VAULT")
        return "{\"version\":1,\"prepared\":true,\"trustedDevice\":false}"
      }
      let endpoint = args["endpoint"] as! String
      let namespace = self.workflowStore { self.isActive(token) }.namespace
      if mail {
        guard let owner = try Self.go({ MobilebridgeOpenNativeAccountResetMail(endpoint, namespace, self.productFixture?.publicCA ?? Data(), &$0) }) else {
          throw NativeSecurityFailure("ACCOUNT_RESET_REJECTED")
        }
        defer { owner.close(); self.mutex.lock(); if self.resetMail === owner { self.resetMail = nil }; self.mutex.unlock() }
        self.mutex.lock()
        guard token == self.epoch else { self.mutex.unlock(); throw NativeSecurityFailure("LOCKED") }
        self.resetMail = owner; self.mutex.unlock()
        return try Self.go { owner.requestEmail(input, error: &$0) }
      }
      let owner = try Self.go { error in
        if call.method == "beginAccountResetQueryOnly" {
          return MobilebridgeOpenNativeAccountResetQuery(endpoint, namespace, input, self.productFixture?.publicCA ?? Data(), &error)
        }
        return MobilebridgeNewNativeAccountReset(endpoint, namespace, input, self.productFixture?.publicCA ?? Data(), &error)
      }
      guard let owner else { throw NativeSecurityFailure("ACCOUNT_RESET_REJECTED") }
      self.mutex.lock()
      guard token == self.epoch, self.resetOwner == nil else {
        self.mutex.unlock(); owner.close(); throw NativeSecurityFailure("LOCKED")
      }
      self.resetOwner = owner; self.resetEndpoint = endpoint; self.mutex.unlock()
      return try Self.go { owner.query(&$0) }
    }
  }

  private func completeAccountReset(token: UInt64) throws -> String {
    let (owner, endpoint) = try accountReset(token: token)
    let commit = try owner.beginCompletion()
    defer { commit.close() }
    closeDAGRegistry()
    let protected = workflowStore { self.isActive(token) }
    try protected.acquireSlot()
    defer { protected.closeSlot() }
    guard try !store.hasPINArtifacts() else { throw NativeSecurityFailure("LOCAL_PROTECTION_STATE") }
    var material = Data(), state = Data()
    var device: MobilebridgeDevice?
    var flow: MobilebridgeVaultWorkflow?
    defer {
      flow?.close(); device?.close()
      material.resetBytes(in: 0..<material.count); state.resetBytes(in: 0..<state.count)
      mutex.lock(); activeWorkflow = nil; mutex.unlock()
    }
    if try store.exists() {
      let authentication = SystemAuthentication.freshContext()
      mutex.lock(); context = authentication; mutex.unlock()
      material = try store.open(context: authentication)
      guard isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      device = try Self.go { MobilebridgeImportProtectedMaterial(material, &$0) }
      material.resetBytes(in: 0..<material.count)
      state = try protected.load()
      flow = try device?.openAtomicWorkflow(endpoint, namespace: protected.namespace, sealed: state,
        additionalCA: productFixture?.publicCA ?? Data(), store: protected)
      mutex.lock(); activeWorkflow = flow; mutex.unlock()
      guard flow != nil else { throw NativeSecurityFailure("LOCAL_PROTECTION_STATE") }
    } else if try protected.exists() {
      throw NativeSecurityFailure("LOCAL_PROTECTION_STATE")
    }
    let cleanup = AccountResetCleanup(clear: {
      guard self.isActive(token) else { throw NativeSecurityFailure("LOCKED") }
      if let current = flow {
        try commit.logoutMatchedWorkflow(current)
        try self.store.delete(); try protected.delete()
        current.close(); flow = nil; device?.close(); device = nil
      }
      protected.closeSlot()
      try protected.acquireSlot()
    }, check: {
      guard self.isActive(token), try !self.store.exists(), try !protected.exists(), try !self.store.hasPINArtifacts() else {
        throw NativeSecurityFailure("LOCAL_PROTECTION_PERSISTENCE")
      }
    })
    return try Self.go { commit.complete(cleanup, error: &$0) }
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

private final class AccountResetCleanup: NSObject, MobilebridgeNativeAccountResetCleanupProtocol {
  private let clear: () throws -> Void
  private let check: () throws -> Void
  init(clear: @escaping () throws -> Void, check: @escaping () throws -> Void) {
    self.clear = clear; self.check = check
  }
  func clearAndReacquireEmpty() throws { try clear(); try check() }
  func checkEmpty() throws { try check() }
}
