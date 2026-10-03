// 只由独立测试构建脚本追加到LocalPINSlot的测试副本，绝不加入Runner target。
// 直接生成合成Record验证私有存储阶段，不表示系统无认证、用户认证或产品PIN获准。
extension LocalPINSlot {
  static func runStorageComponentTests(package: String, root: URL) -> [[String: Any]] {
    var results: [[String: Any]] = []
    func check(_ name: String, _ body: () throws -> Bool) {
      do { results.append(["name": name, "status": try body() ? "PASS" : "FAIL", "scope":"storage-component-only-no-auth-bypass-in-product"]) }
      catch { results.append(["name":name,"status":"FAIL","nativeCode":(error as? NativeSecurityFailure)?.code ?? "UNSPECIFIED"]) }
    }
    func make(_ suffix: String, faults: Faults = Faults()) throws -> LocalPINSlot {
      try LocalPINSlot(package: package, slot: suffix, endpoint: "https://synthetic.invalid",
        directory: root.appendingPathComponent(suffix), systemDirectory: root.appendingPathComponent("empty-system"), faults: faults)
    }
    func publish(_ instance: LocalPINSlot) throws {
      try instance.withOperation { try instance.createFreshRecord(pin: Data("184729".utf8), reentry: Data("184729".utf8)) }
    }
    check("PIN-component-real-Go-close-error-overrides-success") {
      let name = "close-" + UUID().uuidString.lowercased()
      let instance = try make(name, faults: Faults(beforeOwnerRetirement: { throw NativeSecurityFailure("TEST_RETIRE") }))
      do {
        _ = try instance.withOperation {
          guard let core = try NativeBridgePlugin.go({ MobilebridgeNewLocalPINSetup(instance.package, instance.namespace, instance.slot, instance.endpoint, instance, &$0) }) else { throw NativeSecurityFailure("TEST_CORE") }
          return try instance.withCore(core) { "must-not-return-success" }
        }
        return false
      } catch let failure as NativeSecurityFailure { guard failure.code == "PERSISTENCE" else { return false } }
      let reopened = try make(name)
      return try reopened.localState() == .empty
    }
    check("PIN-component-release-error-fails-and-reopen-lock-is-free") {
      let name = "release-" + UUID().uuidString.lowercased()
      let instance = try make(name, faults: Faults(beforeOperationRelease: { throw NativeSecurityFailure("TEST_UNLOCK") }))
      do { _ = try instance.withOperation { "must-not-return-success" }; return false }
      catch let failure as NativeSecurityFailure { guard failure.code == "PERSISTENCE" else { return false } }
      return try make(name).withOperation { true }
    }
    check("PIN-component-failed-initial-save-cleans-exact-Keychain-slot") {
      let name = "save-" + UUID().uuidString.lowercased()
      let instance = try make(name, faults: Faults(beforePacketSave: { throw NativeSecurityFailure("TEST_SAVE") }))
      do { try publish(instance); return false } catch {}
      let reopened = try make(name)
      guard try reopened.localState() == .empty, try !reopened.keyExists() else { return false }
      try publish(reopened)
      defer { try? reopened.forget() }
      return try reopened.localState() == .ready
    }
    check("PIN-component-failed-cleanup-remains-incomplete-until-forget") {
      let name = "cleanup-" + UUID().uuidString.lowercased()
      let instance = try make(name, faults: Faults(beforePacketSave: { throw NativeSecurityFailure("TEST_SAVE") }, beforeKeyDeletion: { throw NativeSecurityFailure("TEST_DELETE") }))
      do { try publish(instance); return false } catch {}
      let reopened = try make(name)
      guard try reopened.localState() == .incomplete, try reopened.keyExists() else { return false }
      do { try publish(reopened); return false } catch {}
      try reopened.forget()
      return try reopened.localState() == .empty && !reopened.keyExists()
    }
    check("PIN-component-Argon2-MAC-limiter-reopen-no-cloud-trust") {
      let name = "argon-" + UUID().uuidString.lowercased()
      let instance = try make(name)
      try publish(instance)
      defer { try? instance.forget() }
      let raw = try instance.withOperation { () throws -> String in
        let packet = try instance.load()
        instance.expectedDigest = try Data(SHA256.hash(data: instance.rawPacket()))
        guard let core = try NativeBridgePlugin.go({ MobilebridgeOpenLocalPINCore(instance.package, instance.namespace, instance.slot, instance.endpoint, packet.scope, instance, &$0) }) else { throw NativeSecurityFailure("TEST_CORE") }
        return try instance.withCore(core) {
          let intent = Data("{\"version\":1,\"operation\":\"view\",\"endpoint\":\"https://synthetic.invalid\"}".utf8)
          return try NativeBridgePlugin.go { core.execute(Data("184729".utf8), completeIntent: intent,
            record: packet.record, sealedWorkflow: packet.workflow, nativeCA: Data(), store: instance, error: &$0) }
        }
      }
      let response = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String:Any]
      guard response["ok"] as? Bool == false, response["code"] as? String == "NOT_TRUSTED" else { return false }
      let reopened = try make(name)
      let attempts = try reopened.attemptMetadata()
      guard attempts.total == 1, attempts.failures == 0 else { return false }
      if SystemAuthentication.probe() == .ready {
        do { _ = try reopened.execute(pin: Data("184729".utf8), completeIntent: Data("{}".utf8)); return false }
        catch let failure as NativeSecurityFailure { guard failure.code == "AUTH_UNAVAILABLE" else { return false } }
        return try reopened.localState() == .upgradeRequired
      }
      return true
    }
    return results
  }
}
