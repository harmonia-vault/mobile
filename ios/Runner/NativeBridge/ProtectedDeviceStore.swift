import Foundation
import LocalAuthentication
import Security

/// 精确的本应用 slot。软件 Ed/X 材料由系统 Keychain ACL 保护；不宣称材料始终在硬件内。
final class ProtectedDeviceStore {
  private let service: String
  private let account = "device-material-v1"
  init(bundleIdentifier: String) { service = bundleIdentifier + ".harmonia.system-device.v1" }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
  }

  func exists() throws -> Bool {
    var q = query
    q[kSecReturnAttributes as String] = true
    let context = SystemAuthentication.freshContext()
    context.interactionNotAllowed = true
    defer { context.invalidate() }
    q[kSecUseAuthenticationContext as String] = context
    let status = SecItemCopyMatching(q as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
    throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE")
  }

  func create(_ material: Data, context: LAContext) throws {
    guard material.count == 72, !((try? exists()) ?? true) else {
      throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE")
    }
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil,
      kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
      throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE")
    }
    var q = query
    q[kSecAttrAccessControl as String] = access
    q[kSecValueData as String] = material
    q[kSecUseAuthenticationContext as String] = context
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
      throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE")
    }
    // 与本次真正认证 context 绑定的 Keychain 取回是成功条件，不拿 LA 布尔值代替取钥。
    var readback = try open(context: context)
    defer { readback.resetBytes(in: 0..<readback.count) }
    guard readback == material else { throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE") }
  }

  func open(context: LAContext) throws -> Data {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecUseAuthenticationContext as String] = context
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    guard status == errSecSuccess, let material = value as? Data, material.count == 72 else {
      if status == errSecUserCanceled { throw NativeSecurityFailure("AUTH_CANCELLED") }
      if status == errSecAuthFailed { throw NativeSecurityFailure("AUTH_FAILED") }
      throw NativeSecurityFailure("PROTECTED_KEYS_UNAVAILABLE")
    }
    return material
  }

  func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound, try !exists() else {
      throw NativeSecurityFailure("PERSISTENCE")
    }
  }
}
