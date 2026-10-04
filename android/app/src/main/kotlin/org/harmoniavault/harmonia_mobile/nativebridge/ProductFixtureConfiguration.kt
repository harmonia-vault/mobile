package org.harmoniavault.harmonia_mobile.nativebridge

import java.net.URI
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64

/** 只有debug独立包的固定编译配置；公共CA不授予账号或设备信任。 */
internal class ProductFixtureConfiguration private constructor(
    val endpoint: String,
    private val caPem: String,
) {
    fun publicCA(): ByteArray = caPem.toByteArray(Charsets.US_ASCII)
    fun acceptsEndpoint(candidate: String): Boolean = candidate == endpoint
    fun attestation(): Map<String, Any> = mapOf(
        "version" to 1, "productFixture" to true, "endpoint" to endpoint, "caPem" to caPem,
    )

    companion object {
        private const val PACKAGE = "org.harmoniavault.harmonia_trial.productfixture"
        private val pem = Regex("\\A-----BEGIN CERTIFICATE-----\\r?\\n([A-Za-z0-9+/=\\r\\n]+)-----END CERTIFICATE-----\\r?\\n?\\z")

        /** 参数只能来自BuildConfig和运行包名，不从MethodChannel接受。 */
        fun fromBuild(debug: Boolean, enabled: Boolean, packageName: String, endpoint: String, encodedCA: String): ProductFixtureConfiguration? {
            if (!enabled) {
                require(endpoint.isEmpty() && encodedCA.isEmpty()) { "测试CA配置不能出现在普通构建。" }
                return null
            }
            require(debug && packageName == PACKAGE) { "测试CA仅允许独立debug包。" }
            require(endpoint.isNotEmpty() && endpoint.length <= 2048 && endpoint == endpoint.trim()) { "测试地址无效。" }
            val uri = URI(endpoint)
            require(uri.scheme == "https" && !uri.isOpaque && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) { "测试地址必须是固定HTTPS。" }
            val host = uri.host?.removePrefix("[")?.removeSuffix("]")
            require(host in setOf("127.0.0.1", "localhost", "10.0.2.2", "::1") && (uri.port == -1 || uri.port in 1..65535)) { "测试CA只允许loopback。" }
            require(uri.rawPath.isNullOrEmpty() && uri.toASCIIString() == endpoint) { "测试地址必须是无路径的canonical origin。" }
            val authority = if (host == "::1") "[::1]" else host
            require(endpoint == "https://" + authority + if (uri.port == -1) "" else ":" + uri.port) { "测试地址不是canonical origin。" }
            require(encodedCA.length <= 90000) { "公共CA超过限制。" }
            val bytes = Base64.getDecoder().decode(encodedCA)
            require(bytes.size in 1..65536 && bytes.all { it >= 0 }) { "公共CA格式无效。" }
            val text = bytes.toString(Charsets.US_ASCII)
            require(pem.matches(text) && !text.contains("PRIVATE KEY")) { "只允许单个公共CA证书。" }
            val certificates = CertificateFactory.getInstance("X.509").generateCertificates(bytes.inputStream())
            require(certificates.size == 1) { "只允许单个公共CA。" }
            val certificate = certificates.single() as X509Certificate
            certificate.checkValidity()
            require(certificate.basicConstraints >= 0 && (certificate.keyUsage == null || certificate.keyUsage[5])) { "测试证书不是CA。" }
            require(certificate.subjectX500Principal == certificate.issuerX500Principal) { "测试CA必须为固定自签根。" }
            certificate.verify(certificate.publicKey)
            return ProductFixtureConfiguration(endpoint, text)
        }
    }
}
