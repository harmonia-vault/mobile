package org.harmoniavault.harmonia_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.harmoniavault.harmonia_mobile.nativebridge.NativeBridgePlugin
import org.harmoniavault.harmonia_mobile.nativebridge.ProductFixtureConfiguration

class MainActivity : FlutterActivity() {
    private var nativeBridge: NativeBridgePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val fixture = ProductFixtureConfiguration.fromBuild(
            BuildConfig.DEBUG, BuildConfig.HARMONIA_PRODUCT_FIXTURE, packageName,
            BuildConfig.HARMONIA_FIXTURE_ENDPOINT, BuildConfig.HARMONIA_FIXTURE_CA_BASE64,
        )
        nativeBridge = NativeBridgePlugin(this, flutterEngine.dartExecutor.binaryMessenger,
            additionalCA = fixture?.publicCA() ?: ByteArray(0), productFixture = fixture)
    }

    override fun onDestroy() {
        nativeBridge?.dispose()
        nativeBridge = null
        super.onDestroy()
    }
}
