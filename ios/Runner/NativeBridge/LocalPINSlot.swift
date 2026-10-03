import Foundation
import CryptoKit
import Security
import Darwin
import Mobilebridge

/// 私有 PIN 平台候选；未接 MethodChannel/UI。资格只能来自实际 LA 的 passcodeNotSet。
/// MAC 钥为 Keychain 软件钥；不声称阻止 root 完整快照回放或 PIN 离线猜测。
final class LocalPINSlot: NSObject, MobilebridgeLocalPINStoreProtocol, MobilebridgeLocalPINLifecycleProtocol {
  // 仅独立原生故障测试注入；不改变认证资格，不来自 MethodChannel。
  struct Faults {
    var beforePacketSave: () throws -> Void = {}
    var beforeOwnerRetirement: () throws -> Void = {}
    var beforeOperationRelease: () throws -> Void = {}
    var beforeKeyDeletion: () throws -> Void = {}
  }
  enum LocalState: String { case empty, ready, incomplete, upgradeRequired }
  private let faults: Faults
  struct Attempts: Codable {
    var revision: Int64
    var recordHash: String
    var total: Int64
    var failures: Int64
    var pendingAttempt: String?
    var delaySeconds: UInt32
  }
  private struct Packet: Codable {
    var version: Int
    var package: String
    var namespace: String
    var slot: String
    var endpoint: String
    var scope: String
    var record: Data
    var attempts: Attempts
    var workflow: Data
    var upgradeRequired: Bool
  }
  private struct Envelope: Codable { var payload: Data; var mac: Data }
  private struct Provision: Decodable { let profile: String; let recordBase64: String; let attempts: Attempts }
  private let package: String
  private let namespace: String
  private let slot: String
  private let endpoint: String
  private let directory: URL
  private let systemDirectory: URL
  private let systemStore: ProtectedDeviceStore
  private let mutex = NSLock()
  private var operationFD: Int32 = -1
  private var attemptFD: Int32 = -1
  private var expectedDigest: Data?
  private var activeCore: MobilebridgeLocalPINCore?
  private let registry: MobilebridgeRecoveryRegistry
  private var packetURL: URL { directory.appendingPathComponent("pin-state-v1.packet") }
  private var keyQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: package + ".harmonia.pin-mac.v1",
     kSecAttrAccount as String: slot, kSecAttrSynchronizable as String: false]
  }

  init(package: String, slot: String, endpoint: String, directory: URL, systemDirectory: URL, faults: Faults = Faults()) throws {
    guard slot.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
      throw NativeSecurityFailure("INVALID_COMMAND")
    }
    self.faults = faults
    self.package = package; self.slot = slot; self.endpoint = endpoint
    self.namespace = package + "\0harmonia/ios-pin/v1\0" + slot
    self.directory = directory; self.systemDirectory = systemDirectory
    self.systemStore = ProtectedDeviceStore(bundleIdentifier: package)
    guard let registry = try NativeBridgePlugin.go({ MobilebridgeNewRecoveryRegistry(package, slot, &$0) }) else {
      throw NativeSecurityFailure("LOCKED")
    }
    self.registry = registry
    super.init()
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
    guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  private func lockFile(_ filename: String) throws -> Int32 {
    try prepareDirectory()
    let fd = Darwin.open(directory.appendingPathComponent(filename).path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { Darwin.close(fd); throw NativeSecurityFailure("BUSY") }
    return fd
  }
  private func withOperation<T>(_ operation: () throws -> T) throws -> T {
    guard mutex.try() else { throw NativeSecurityFailure("BUSY") }
    defer { mutex.unlock() }
    operationFD = try lockFile("operation.lock")
    let outcome = Result { try operation() }
    var cleanupFailed = false
    if attemptFD >= 0 {
      do { try release() } catch { cleanupFailed = true }
    }
    do { try faults.beforeOperationRelease() } catch { cleanupFailed = true }
    let unlock = flock(operationFD, LOCK_UN)
    let closed = Darwin.close(operationFD)
    operationFD = -1; expectedDigest = nil
    if unlock != 0 || closed != 0 || cleanupFailed { throw NativeSecurityFailure("PERSISTENCE") }
    return try outcome.get()
  }
  private func withCore<T>(_ core: MobilebridgeLocalPINCore, _ operation: () throws -> T) throws -> T {
    activeCore = core
    let outcome = Result { try operation() }
    var closed = true
    do { try core.close() } catch { closed = false }
    activeCore = nil
    guard closed else { throw NativeSecurityFailure("PERSISTENCE") }
    return try outcome.get()
  }
  private func keyExists() throws -> Bool {
    var query = keyQuery
    let context = SystemAuthentication.freshContext(); context.interactionNotAllowed = true
    defer { context.invalidate() }
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnAttributes as String] = true
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
    throw NativeSecurityFailure("PERSISTENCE")
  }
  private func stateUnlocked() throws -> LocalState {
    let hasPacket = FileManager.default.fileExists(atPath: packetURL.path)
    let hasKey = try keyExists()
    if !hasPacket && !hasKey { return .empty }
    guard hasPacket && hasKey else { return .incomplete }
    do { return try load().upgradeRequired ? .upgradeRequired : .ready }
    catch { return .incomplete }
  }
  func localState() throws -> LocalState { try withOperation { try stateUnlocked() } }

  private func integrityKey(create: Bool = false) throws -> Data {
    let context = SystemAuthentication.freshContext(); context.interactionNotAllowed = true
    defer { context.invalidate() }
    var query = keyQuery
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecSuccess, let data = value as? Data, data.count == 32 {
      guard !create else { throw NativeSecurityFailure("PERSISTENCE") }
      return data
    }
    guard create, status == errSecItemNotFound else { throw NativeSecurityFailure("PERSISTENCE") }
    var data = Data(count: 32)
    guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    var insert = keyQuery
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
      data.resetBytes(in: 0..<data.count); throw NativeSecurityFailure("PERSISTENCE")
    }
    return data
  }
  private func rawPacket() throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: packetURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 << 20 else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    return try Data(contentsOf: packetURL)
  }
  private func load() throws -> Packet {
    let raw = try rawPacket()
    let envelope = try JSONDecoder().decode(Envelope.self, from: raw)
    guard try Self.encode(envelope) == raw else { throw NativeSecurityFailure("PERSISTENCE") }
    var key = try integrityKey(); defer { key.resetBytes(in: 0..<key.count) }
    guard HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: SymmetricKey(data: key)) else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    let packet = try JSONDecoder().decode(Packet.self, from: envelope.payload)
    guard try Self.encode(packet) == envelope.payload, packet.version == 1,
          packet.package == package, packet.namespace == namespace, packet.slot == slot, packet.endpoint == endpoint,
          !packet.scope.isEmpty, packet.scope.utf8.count <= 4096, packet.record.count <= 8192,
          packet.workflow.count <= (8 << 20) + 8192,
          packet.attempts.revision > 0, packet.attempts.total >= 0,
          packet.attempts.failures >= 0, packet.attempts.failures <= packet.attempts.total else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    return packet
  }
  private func save(_ packet: Packet, creating: Bool = false) throws {
    guard operationFD >= 0 else { throw NativeSecurityFailure("BUSY") }
    if !creating {
      guard let expectedDigest, try Data(SHA256.hash(data: rawPacket())) == expectedDigest else {
        throw NativeSecurityFailure("PERSISTENCE")
      }
    } else if FileManager.default.fileExists(atPath: packetURL.path) { throw NativeSecurityFailure("PERSISTENCE") }
    try faults.beforePacketSave()
    let payload = try Self.encode(packet)
    var key = try integrityKey(); defer { key.resetBytes(in: 0..<key.count) }
    let envelope = Envelope(payload: payload, mac: Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))))
    let raw = try Self.encode(envelope)
    guard raw.count <= 16 << 20 else { throw NativeSecurityFailure("PERSISTENCE") }
    let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
    try raw.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw NativeSecurityFailure("PERSISTENCE") }
        offset += n
      }
    }
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
    guard fsync(fd) == 0, rename(temporary.path, packetURL.path) == 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    try syncDirectory()
    guard try rawPacket() == raw else { throw NativeSecurityFailure("PERSISTENCE") }
    _ = try load()
    expectedDigest = Data(SHA256.hash(data: raw))
  }
  private func syncDirectory() throws {
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw NativeSecurityFailure("PERSISTENCE") }
  }
  private func requireEligibility(existing: Bool) throws {
    let state = SystemAuthentication.probe()
    if state == .ready, existing {
      var packet = try load()
      expectedDigest = try Data(SHA256.hash(data: rawPacket()))
      packet.upgradeRequired = true
      try save(packet)
      registry.clear()
    }
    guard state == .noDevicePasscode, try !systemStore.exists(),
      !FileManager.default.fileExists(atPath: systemDirectory.appendingPathComponent("workflow-state-v1.gcm").path) else {
      throw NativeSecurityFailure("AUTH_UNAVAILABLE")
    }
    if existing, try load().upgradeRequired { throw NativeSecurityFailure("LOCKED") }
  }
  private static func decodeRawBase64(_ raw: String) -> Data? {
    let text = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
    guard let decoded = Data(base64Encoded: padded), decoded.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == raw else { return nil }
    return decoded
  }

  func create(pin: Data, reentry: Data) throws {
    try withOperation {
      try requireEligibility(existing: false)
      try createFreshRecord(pin: pin, reentry: reentry)
    }
  }
  // 私有存储阶段；产品唯一调用点在真实资格检查后。测试target单独验证失败清理。
  private func createFreshRecord(pin: Data, reentry: Data) throws {
    guard try stateUnlocked() == .empty else { throw NativeSecurityFailure("PERSISTENCE") }
    guard let core = try NativeBridgePlugin.go({ MobilebridgeNewLocalPINSetup(package, namespace, slot, endpoint, self, &$0) }) else {
      throw NativeSecurityFailure("GO_OR_KEYSTORE_REJECTED")
    }
    var createdOwnKey = false
    do {
      try withCore(core) {
        let scope = try NativeBridgePlugin.go { core.scopeJSON(&$0) }
        let provision = try JSONDecoder().decode(Provision.self, from: core.create(pin, fullReentry: reentry))
        guard provision.profile == "harmonia/native-pin-provision/v1", let record = Self.decodeRawBase64(provision.recordBase64) else {
          throw NativeSecurityFailure("PERSISTENCE")
        }
        var key = try integrityKey(create: true); createdOwnKey = true; key.resetBytes(in: 0..<key.count)
        try save(Packet(version: 1, package: package, namespace: namespace, slot: slot, endpoint: endpoint,
          scope: scope, record: record, attempts: provision.attempts, workflow: Data(), upgradeRequired: false), creating: true)
      }
    } catch {
      // 仅清理本次由empty创建的slot；失败保留incomplete，必须显式forget，不自动覆盖。
      if createdOwnKey {
        do { try clearSlot() } catch { throw NativeSecurityFailure("PERSISTENCE") }
      }
      throw error
    }
  }

  func execute(pin: Data, completeIntent: Data) throws -> String {
    try withOperation {
      try requireEligibility(existing: true)
      let packet = try load()
      expectedDigest = try Data(SHA256.hash(data: rawPacket()))
      guard let core = try NativeBridgePlugin.go({ MobilebridgeOpenLocalPINCore(package, namespace, slot, endpoint, packet.scope, self, &$0) }) else {
        throw NativeSecurityFailure("GO_OR_KEYSTORE_REJECTED")
      }
      return try withCore(core) {
        let response = try NativeBridgePlugin.go {
          core.execute(pin, completeIntent: completeIntent, record: packet.record,
            sealedWorkflow: packet.workflow, nativeCA: Data(), store: self, error: &$0)
        }
        if let value = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], value["requiresDeviceDeletion"] as? Bool == true {
          try clearSlot()
        }
        return response
      }
    }
  }
  /// 只清本 slot；不解包旧钥匙，不发任何云请求，重新创建必有新随机设备/gen/epoch。
  func forget() throws { try withOperation { try clearSlot() } }
  private func clearSlot() throws {
    registry.clear()
    try faults.beforeKeyDeletion()
    let status = SecItemDelete(keyQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeSecurityFailure("PERSISTENCE") }
    if FileManager.default.fileExists(atPath: packetURL.path) {
      try FileManager.default.removeItem(at: packetURL); try syncDirectory()
    }
    guard !FileManager.default.fileExists(atPath: packetURL.path), try !keyExists() else { throw NativeSecurityFailure("PERSISTENCE") }
    expectedDigest = nil
  }
  // Go 的整个 KDF 尝试锁独立于完整业务 gate；回调绝不重入 core.Close/Cancel。
  func acquire() throws {
    guard operationFD >= 0, attemptFD < 0 else { throw NativeSecurityFailure("BUSY") }
    attemptFD = try lockFile("attempt.lock")
  }
  func release() throws {
    guard attemptFD >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    let fd = attemptFD; attemptFD = -1
    let unlock = flock(fd, LOCK_UN); let closed = Darwin.close(fd)
    guard unlock == 0, closed == 0 else { throw NativeSecurityFailure("PERSISTENCE") }
  }
  func loadAttempts(_ error: NSErrorPointer) -> String {
    do {
      guard attemptFD >= 0 else { throw NativeSecurityFailure("BUSY") }
      return String(decoding: try Self.encode(load().attempts), as: UTF8.self)
    } catch let failure { error?.pointee = failure as NSError; return "" }
  }
  func commitAttempts(_ expectedRevision: Int64, nextJSON: String?) throws {
    guard attemptFD >= 0, let nextJSON, nextJSON.utf8.count <= 1024 else { throw NativeSecurityFailure("PERSISTENCE") }
    var packet = try load()
    let next = try JSONDecoder().decode(Attempts.self, from: Data(nextJSON.utf8))
    guard expectedRevision > 0, expectedRevision < Int64.max, packet.attempts.revision == expectedRevision,
      next.revision == expectedRevision + 1, next.recordHash == packet.attempts.recordHash,
      next.total >= packet.attempts.total, next.failures >= 0, next.failures <= next.total else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    packet.attempts = next; try save(packet)
  }
  func saveWorkflowSealed(_ bytes: Data?) throws {
    guard let bytes, bytes.count >= 40, bytes.count <= (8 << 20) + 8192,
          bytes.prefix(8) == Data("HARMST01".utf8) else { throw NativeSecurityFailure("PERSISTENCE") }
    var packet = try load(); packet.workflow = bytes; try save(packet)
  }
  func retireOwners() throws { registry.clear(); try faults.beforeOwnerRetirement() }

  /// 仅原生测试/诊断可取非秘密计数，不经产品通道。
  func attemptMetadata() throws -> Attempts { try withOperation { try load().attempts } }
}
