import Foundation
import LocalAuthentication

/// 只有完整 deviceOwnerAuthentication 的 passcodeNotSet 才是无系统认证。
/// 取消、锁定、硬件暂不可用以及未知错误一律不能降级到应用 PIN。
enum SystemAuthenticationState: String {
  case ready, noDevicePasscode, temporarilyUnavailable, unknown
}

struct NativeSecurityFailure: Error {
  let code: String
  init(_ code: String) { self.code = code }
}

enum SystemAuthentication {
  static func classify(canEvaluate: Bool, error: NSError?) -> SystemAuthenticationState {
    if canEvaluate { return .ready }
    guard let error, error.domain == LAError.errorDomain,
          let code = LAError.Code(rawValue: error.code) else { return .unknown }
    if code == .passcodeNotSet { return .noDevicePasscode }
    switch code {
    case .userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback,
         .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled,
         .notInteractive, .invalidContext:
      return .temporarilyUnavailable
    default: return .unknown
    }
  }

  static func probe() -> SystemAuthenticationState {
    let context = freshContext()
    defer { context.invalidate() }
    var error: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    return classify(canEvaluate: available, error: error)
  }

  static func freshContext() -> LAContext {
    let context = LAContext()
    context.touchIDAuthenticationAllowableReuseDuration = 0
    context.localizedReason = "验证本次和弦设备钥匙操作"
    context.localizedCancelTitle = "取消"
    return context
  }

  static func failure(_ error: Error?) -> NativeSecurityFailure {
    guard let e = error as NSError?, e.domain == LAError.errorDomain,
          let code = LAError.Code(rawValue: e.code) else { return NativeSecurityFailure("AUTH_FAILED") }
    switch code {
    case .userCancel, .appCancel, .systemCancel: return NativeSecurityFailure("AUTH_CANCELLED")
    case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled: return NativeSecurityFailure("AUTH_UNAVAILABLE")
    default: return NativeSecurityFailure("AUTH_FAILED")
    }
  }
}
