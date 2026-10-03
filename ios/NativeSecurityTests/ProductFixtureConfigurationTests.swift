// 配置组件测试：不模拟 LA、钥匙、设备信任或产品操作。
import Foundation
@main struct ConfigurationTests {
 static func main() throws {
  let good = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let positive = try ProductFixtureConfiguration.decodeResource(good)
  let object = try JSONSerialization.jsonObject(with:good) as! [String:Any]
  var count=0
  func rejected(_ value:[String:Any]) throws {
   do { _ = try ProductFixtureConfiguration.decodeResource(JSONSerialization.data(withJSONObject:value));fatalError("Invalid fixture was accepted") }
   catch is NativeSecurityFailure {count += 1}
  }
  for endpoint in ["http://127.0.0.1:5593","https://127.0.0.1:5594","https://localhost:5593","https://synthetic.invalid:5593","https://127.0.0.1:5593/","https://127.0.0.1:5593?x=1"] {
   var o=object;o["endpoint"]=endpoint;try rejected(o)
  }
  var extra=object;extra["trusted"]=true;try rejected(extra)
  for pem in ["PRIVATE KEY",object["caPem"] as! String + (object["caPem"] as! String),"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",String(repeating:"A",count:65537)] {
   var o=object;o["caPem"]=pem;try rejected(o)
  }
  guard positive.attestation.count==4, positive.acceptsWorkflow("{\"endpoint\":\"https://127.0.0.1:5593\"}"),
    !positive.acceptsWorkflow(nil),!positive.acceptsWorkflow("{}"),!positive.acceptsWorkflow("{\"endpoint\":\"https://localhost:5593\"}") else {fatalError("Endpoint guard failed")}
  print("FIXTURE_CONFIGURATION_PASS valid=1 negative=\(count) endpointGuard=4")
 }
}
