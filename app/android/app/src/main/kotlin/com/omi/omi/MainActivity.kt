package com.omi.omi

import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CAPTURE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, CaptureForegroundService::class.java)
                    intent.putExtra(
                        CaptureForegroundService.EXTRA_DEVICE_NAME,
                        call.argument<String>("deviceName") ?: "Omi",
                    )
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            ContextCompat.startForegroundService(this, intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        // Android 12+ refuses foreground-service starts from the
                        // background, and OEM policies can refuse outright. Say so
                        // rather than letting the app believe capture is protected.
                        result.success(false)
                    }
                }
                "stop" -> {
                    stopService(Intent(this, CaptureForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val BACKGROUND_CAPTURE_CHANNEL = "omi/background_capture"
    }
}
