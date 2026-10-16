package com.kocierik.echo

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "echo/device": "maker|model" ("Google|Pixel 8"), named in phone_name.dart
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "echo/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "model") {
                    result.success("${Build.MANUFACTURER}|${Build.MODEL}")
                } else {
                    result.notImplemented()
                }
            }
    }
}
