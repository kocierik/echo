package com.kocierik.echo

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** The screen: it borrows the process-wide engine (EchoEngine) and never destroys it. */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = EchoEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Asking for the calendar permission needs a screen
        EchoEngine.calendar.activity = this
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (EchoEngine.calendar.activity === this) EchoEngine.calendar.activity = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        EchoEngine.calendar.onPermissionsResult(requestCode, grantResults)
    }
}
