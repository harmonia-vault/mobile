package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.os.Build

/** 只表示本机保护路线，不表示账号或设备可信。 */
internal enum class PinSystemVerdict { SYSTEM_READY, NO_SYSTEM_AUTH, BLOCKED }

/** 纯分类用于有限主机测试；生产入口不会接收调用方 snapshot 或 bool。 */
internal object PinCapabilityPolicy {
    fun classify(api: Int, deviceSecure: Boolean?, combined: Int?, strong: Int?): PinSystemVerdict {
        if (api < 30 || deviceSecure == null || combined == null || strong == null) return PinSystemVerdict.BLOCKED
        if (combined == 0 && (deviceSecure || strong == 0)) return PinSystemVerdict.SYSTEM_READY
        if (deviceSecure) return PinSystemVerdict.BLOCKED
        // 11 = NONE_ENROLLED, 12 = NO_HARDWARE. HW_UNAVAILABLE/security-update/
        // lockout/unsupported/未知均不得解释为没有系统认证。
        val absent = setOf(11, 12)
        return if (combined in absent && strong in absent) PinSystemVerdict.NO_SYSTEM_AUTH else PinSystemVerdict.BLOCKED
    }
}

/** 生产资格只从私有实际 Android 服务读取，没有 fake-NONE/caller-bool 参数。 */
internal class PinCapabilityClassifier(private val context: Context) {
    fun current(): PinSystemVerdict = try {
        if (Build.VERSION.SDK_INT < 30) PinSystemVerdict.BLOCKED else {
            val keyguard = context.getSystemService(KeyguardManager::class.java)
            val biometrics = context.getSystemService(BiometricManager::class.java)
            PinCapabilityPolicy.classify(
                Build.VERSION.SDK_INT,
                keyguard?.isDeviceSecure,
                biometrics?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL),
                biometrics?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG),
            )
        }
    } catch (_: Exception) { PinSystemVerdict.BLOCKED }
}
