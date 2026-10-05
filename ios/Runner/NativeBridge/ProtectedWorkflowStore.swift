import Foundation
import Darwin
import Mobilebridge

/// 仅接 Go 已密封 HARMST02；文件与目录 fsync、原子 rename、读回全部成功才确认保存。
final class ProtectedWorkflowStore: NSObject, MobilebridgeAtomicSealedStateStoreProtocol {
  let namespace: String
  private let directory: URL
  private let file: URL
  private let isActive: () -> Bool
  private let limit = (8 << 20) + 8192
  private var lockFD: Int32 = -1

  init(bundleIdentifier: String, directory: URL, isActive: @escaping () -> Bool) {
    self.directory = directory
    self.file = directory.appendingPathComponent("workflow-state-v1.gcm")
    self.namespace = bundleIdentifier + "\0harmonia/workflow-state/v1\0workflow-state-v1.gcm"
    self.isActive = isActive
  }

  private func validate(_ packet: Data) throws {
    guard packet.count >= 40, packet.count <= limit,
          packet.prefix(8) == Data("HARMST02".utf8) else { throw NativeSecurityFailure("PERSISTENCE") }
  }

  // 同一固定槽的恢复、普通写入和重置清理共用 OS 排他锁。
  func acquireSlot() throws {
    guard isActive(), lockFD == -1 else { throw NativeSecurityFailure("LOCKED") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    let fd = Darwin.open(directory.appendingPathComponent("operation.lock").path,
      O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(fd); throw NativeSecurityFailure("BUSY")
    }
    lockFD = fd
  }

  func closeSlot() {
    if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
  }
  deinit { closeSlot() }

  func checkSealed(_ expected: Data?) throws {
    guard lockFD >= 0, try load() == (expected ?? Data()) else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
  }

  func compareAndSwapSealed(_ expected: Data?, next: Data?) throws {
    try checkSealed(expected)
    try saveSealed(next)
  }

  func exists() throws -> Bool {
    guard isActive() else { throw NativeSecurityFailure("LOCKED") }
    do {
      _ = try FileManager.default.attributesOfItem(atPath: file.path)
      return true
    } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
        [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
      return false
    }
  }

  func load() throws -> Data {
    guard isActive() else { throw NativeSecurityFailure("LOCKED") }
    guard try exists() else { return Data() }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber, size.intValue <= limit else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    let packet = try Data(contentsOf: file)
    try validate(packet)
    return packet
  }

  func saveSealed(_ packet: Data?) throws {
    guard let packet, isActive(), lockFD >= 0 else { throw NativeSecurityFailure("LOCKED") }
    try validate(packet)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
    var excluded = directory
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
    try packet.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { throw NativeSecurityFailure("PERSISTENCE") }
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw NativeSecurityFailure("PERSISTENCE") }
        offset += n
      }
    }
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
    guard fsync(fd) == 0, isActive(), rename(temporary.path, file.path) == 0 else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
    try syncDirectory()
    guard try load() == packet else { throw NativeSecurityFailure("PERSISTENCE") }
  }

  private func syncDirectory() throws {
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw NativeSecurityFailure("PERSISTENCE") }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw NativeSecurityFailure("PERSISTENCE") }
  }

  func delete() throws {
    guard isActive(), lockFD >= 0 else { throw NativeSecurityFailure("LOCKED") }
    if try exists() {
      try FileManager.default.removeItem(at: file)
      try syncDirectory()
    }
    guard try !exists() else { throw NativeSecurityFailure("PERSISTENCE") }
  }
}
