package org.harmoniavault.harmonia_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.harmoniavault.harmonia_mobile.nativebridge.NativeBridgePlugin

class MainActivity : FlutterActivity() {
    private var nativeBridge: NativeBridgePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeBridge = NativeBridgePlugin(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        nativeBridge?.dispose()
        nativeBridge = null
        super.onDestroy()
    }
}
