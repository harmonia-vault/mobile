import java.net.URI
import java.nio.file.Files
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 只读固定ignored公共CA配置；不从运行通道、环境参数或任意路径接受CA。
val productFixtureRaw = providers.gradleProperty("harmoniaProductFixture").getOrElse("false")
check(productFixtureRaw in setOf("true", "false")) { "harmoniaProductFixture只能为true/false。" }
val productFixture = productFixtureRaw == "true"
val nativeFixture = providers.gradleProperty("harmoniaNativeFixture").getOrElse("false") == "true"
check(!(productFixture && nativeFixture)) { "productfixture与nativefixture不能混合。" }
if (productFixture) {
    check(gradle.startParameter.taskNames.none {
        val name = it.substringAfterLast(':').lowercase()
        name.contains("release") || name.contains("profile") || name == "assemble" || name == "build"
    }) { "productfixture只允许显式debug任务，拒绝release/profile/全assemble构建。" }
}
val productFixtureData: Map<String, String> = if (productFixture) {
    val config = file("../../build/native/product-fixture.json")
    check(config.isFile && !Files.isSymbolicLink(config.toPath()) && config.length() in 1..70000) { "缺少固定ignored公共CA测试配置。" }
    val parsed = runCatching { JsonSlurper().parseText(config.readText(Charsets.UTF_8)) as? Map<*, *> }.getOrNull()
    check(parsed != null && parsed.keys == setOf("endpoint", "caPem") && parsed.values.all { it is String }) { "公共CA配置字段无效。" }
    val endpoint = parsed["endpoint"] as String
    val ca = parsed["caPem"] as String
    val uri = runCatching { URI(endpoint) }.getOrNull()
    val host = uri?.host?.removePrefix("[")?.removeSuffix("]")
    val authority = if (host == "::1") "[::1]" else host
    check(uri != null && endpoint.length in 1..2048 && endpoint == endpoint.trim() && uri.scheme == "https" &&
        !uri.isOpaque && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
        uri.rawPath.isNullOrEmpty() && host in setOf("127.0.0.1", "localhost", "10.0.2.2", "::1") &&
        (uri.port == -1 || uri.port in 1..65535) && endpoint == "https://" + authority + if (uri.port == -1) "" else ":" + uri.port
    ) { "公共CA必须绑定canonical loopback HTTPS origin。" }
    val certificateOnly = Regex("\\A-----BEGIN CERTIFICATE-----\\r?\\n([A-Za-z0-9+/=\\r\\n]+)-----END CERTIFICATE-----\\r?\\n?\\z")
    check(ca.toByteArray(Charsets.UTF_8).size in 1..65536 && certificateOnly.matches(ca) && !ca.contains("PRIVATE KEY")) { "只允许单个公共CA证书。" }
    val certificates = runCatching { CertificateFactory.getInstance("X.509").generateCertificates(ca.byteInputStream(Charsets.US_ASCII)) }.getOrNull()
    check(certificates != null && certificates.size == 1) { "公共CA证书无效。" }
    val certificate = certificates.single() as X509Certificate
    check(runCatching {
        certificate.checkValidity()
        check(certificate.basicConstraints >= 0 && (certificate.keyUsage == null || certificate.keyUsage[5]))
        check(certificate.subjectX500Principal == certificate.issuerX500Principal)
        certificate.verify(certificate.publicKey)
    }.isSuccess) { "测试CA须是当前有效的自签根。" }
    mapOf("endpoint" to endpoint, "encodedCA" to Base64.getEncoder().encodeToString(ca.toByteArray(Charsets.US_ASCII)))
} else emptyMap()

// 任务图再次检查间接release/profile依赖。
if (productFixture) gradle.taskGraph.whenReady {
    check(allTasks.none { it.project == project && (it.name.contains("Release") || it.name.contains("Profile")) }) {
        "productfixture拒绝release/profile任务图。"
    }
}


android {
    namespace = "org.harmoniavault.harmonia_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures { buildConfig = true }

    signingConfigs {
        create("trialDebug") {
            storeFile = file("../../build/native/trial-debug.jks")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("trialDebug")
            if (productFixture) {
                applicationIdSuffix = ".productfixture"
                buildConfigField("boolean", "HARMONIA_PRODUCT_FIXTURE", "true")
                buildConfigField("String", "HARMONIA_FIXTURE_ENDPOINT", "\"" + productFixtureData.getValue("endpoint") + "\"")
                buildConfigField("String", "HARMONIA_FIXTURE_CA_BASE64", "\"" + productFixtureData.getValue("encodedCA") + "\"")
            }
            // 原生验收使用独立合成包名，保留已有预览应用及其数据/签名。
            if (providers.gradleProperty("harmoniaNativeFixture").getOrElse("false") == "true") {
                applicationIdSuffix = ".nativefixture"
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.harmoniavault.harmonia_trial"
        buildConfigField("boolean", "HARMONIA_PRODUCT_FIXTURE", "false")
        buildConfigField("String", "HARMONIA_FIXTURE_ENDPOINT", "\"\"")
        buildConfigField("String", "HARMONIA_FIXTURE_CA_BASE64", "\"\"")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30 // 每次 CryptoObject 支持强生物或设备密码认证。
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters.add("arm64-v8a") }
    }


}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 源码公开，固定 Go/BoringSSL 本机任务生成 AAR，产物只在 ignored build 目录。
dependencies {
    implementation(files("../../build/native/harmonia-go.aar"))
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("junit:junit:4.13.2")
}

// 直接调用Gradle也必须给出清晰的源码构建入口，不能静默省略Go核心。
tasks.named("preBuild").configure {
    doFirst {
        check(file("../../build/native/harmonia-go.aar").isFile) {
            "缺少本机Go AAR；请在mobile目录先运行 mise run go-native-build。"
        }
    }
}
