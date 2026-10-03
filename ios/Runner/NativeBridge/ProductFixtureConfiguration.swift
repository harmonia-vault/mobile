import Foundation
import Security

/// 仅独立 Simulator Debug 包的固定公共 CA 配置，不授予账号或设备信任。
struct ProductFixtureConfiguration {
  static let bundleIdentifier = "org.harmoniavault.ios.productfixture"
  static let endpoint = "https://127.0.0.1:5593"
  private let caPEM: String
  var publicCA: Data { Data(caPEM.utf8) }
  var attestation: [String: Any] {
    ["version": 1, "productFixture": true, "endpoint": Self.endpoint, "caPem": caPEM]
  }
  func acceptsWorkflow(_ command: String?) -> Bool {
    guard let command, let value = try? JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any],
          value["endpoint"] as? String == Self.endpoint else { return false }
    return true
  }
  static func fromBundle() throws -> Self? {
    let url = Bundle.main.url(forResource: "HarmoniaProductFixture", withExtension: "json")
    #if DEBUG && HARMONIA_PRODUCT_FIXTURE && targetEnvironment(simulator)
    guard Bundle.main.bundleIdentifier == bundleIdentifier, let url else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    guard size > 0, size <= 70000 else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    return try decodeResource(Data(contentsOf: url))
    #else
    // 普通/Release 中若误放测试资源，一律关闭原生桥，不默默接受或忽略。
    guard url == nil else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    return nil
    #endif
  }
  /// 内部纯配置校验；输入只来自本 App 编译后的资源，不接收 MethodChannel 参数。
  static func decodeResource(_ data: Data) throws -> Self {
    guard data.count <= 70000,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(value.keys) == ["endpoint", "caPem"], value["endpoint"] as? String == endpoint,
          let pem = value["caPem"] as? String, pem.utf8.count <= 65536,
          pem.utf8.allSatisfy({ $0 < 128 }), !pem.contains("PRIVATE KEY") else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    let pattern = #"\A-----BEGIN CERTIFICATE-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----\r?\n?\z"#
    let expression = try NSRegularExpression(pattern: pattern)
    let ns = pem as NSString
    guard let match = expression.firstMatch(in: pem, range: NSRange(location: 0, length: ns.length)),
          match.range.length == ns.length,
          let der = Data(base64Encoded: ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")),
          let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
          SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
          SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
          SecTrustEvaluateWithError(trust, nil) else { throw NativeSecurityFailure("FIXTURE_CONFIGURATION") }
    return Self(caPEM: pem)
  }
}
