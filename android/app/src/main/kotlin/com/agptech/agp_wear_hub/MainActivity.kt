
package com.agptech.agp_wear_hub

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.agptech.agp_wear_hub/call"
    private var qcSdkPlugin: QcSdkPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // QC Wireless SDK bridge — pass Activity context for proper BLE GATT
        try {
            qcSdkPlugin = QcSdkPlugin(this, flutterEngine)
        } catch (e: Throwable) {
            android.util.Log.e("MainActivity", "QcSdkPlugin init FAILED", e)
        }

        // Phone call channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "directCall") {
                    val number = call.argument<String>("number")
                    if (number != null) {
                        val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number"))
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.error("NO_NUMBER", "Număr lipsă", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        qcSdkPlugin?.dispose()
        super.onDestroy()
    }
}
