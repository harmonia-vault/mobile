package org.harmoniavault.harmonia_mobile.nativebridge

import java.io.File
import java.util.Base64

/** 只验编译配置与边界，不冒称Android认证或Flutter/TLS用户链。 */
object ProductFixtureConfigurationHostTest {
    @JvmStatic fun main(args: Array<String>) {
        val ca = File(args.single()).readText(Charsets.US_ASCII)
        val encoded = Base64.getEncoder().encodeToString(ca.toByteArray(Charsets.US_ASCII))
        val pkg = "org.harmoniavault.harmonia_trial.productfixture"
        val endpoint = "https://10.0.2.2:4443"
        val config = ProductFixtureConfiguration.fromBuild(true, true, pkg, endpoint, encoded)!!
        check(config.attestation().keys == setOf("version", "productFixture", "endpoint", "caPem"))
        check(config.attestation()["productFixture"] == true && config.attestation()["caPem"] == ca)
        check(config.acceptsEndpoint(endpoint) && !config.acceptsEndpoint("https://127.0.0.1:4443"))
        check(config.publicCA().contentEquals(ca.toByteArray(Charsets.US_ASCII)))
        check(ProductFixtureConfiguration.fromBuild(true, false, "org.harmoniavault.harmonia_mobile", "", "") == null)
        fun rejected(debug: Boolean = true, enabled: Boolean = true, packageName: String = pkg, url: String = endpoint, publicCA: String = encoded) {
            var rejected = false
            try { ProductFixtureConfiguration.fromBuild(debug, enabled, packageName, url, publicCA) }
            catch (_: Exception) { rejected = true }
            check(rejected) { "无效测试配置未拒绝。" }
        }
        rejected(debug = false)
        rejected(enabled = false)
        rejected(packageName = "org.harmoniavault.harmonia_mobile")
        rejected(packageName = "org.harmoniavault.harmonia_mobile.productfixture")
        rejected(url = "https://fixture.example.invalid:4443")
        rejected(url = "http://10.0.2.2:4443")
        rejected(url = "https://10.0.2.2:4443/")
        rejected(url = "https://10.0.2.2:04443")
        rejected(url = "https://10.0.2.2:4443?ca=override")
        rejected(url = "https://synthetic@10.0.2.2:4443")
        rejected(url = "https://10.0.2.2:4443#public")
        rejected(publicCA = "")
        rejected(publicCA = "!")
        rejected(publicCA = Base64.getEncoder().encodeToString((ca + ca).toByteArray()))
        // 只有合成header，无私钥body；固定片段组成相同运行时负例，避免源码秘密scanner误报。
        rejected(publicCA = Base64.getEncoder().encodeToString(("-----BEGIN " + "PRIVATE " + "KEY-----").toByteArray()))
        println("PASS productfixture host16 boundary cases; Android/real TLS/product UNRUN")
    }
}
