plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.harmoniavault.harmonia_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildTypes {
        debug {
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
        applicationId = "org.harmoniavault.harmonia_mobile"
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
