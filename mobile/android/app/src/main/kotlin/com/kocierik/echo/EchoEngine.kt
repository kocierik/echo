package com.kocierik.echo

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * One Flutter engine for the whole process, kept when the activity goes. The Dart side
 * (Bluetooth relay, uploads, commands) then keeps running while EchoStatusService holds the
 * process, also after Echo is swiped away from the recent apps; MainActivity attaches to it.
 *
 * The channels that need no activity are set up here, before Dart starts.
 */
object EchoEngine {
    private const val ID = "echo"

    lateinit var calendar: CalendarBridge
        private set

    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        val messenger = engine.dartExecutor.binaryMessenger

        // "echo/device": the phone's model (phone_name.dart) and Echo's App info page
        MethodChannel(messenger, "echo/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "model" -> result.success("${Build.MANUFACTURER}|${Build.MODEL}")
                // Spoken answers (answer_speaker.dart): is sound going to headphones?
                "headphones" -> {
                    val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val worn = mutableSetOf(
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_USB_HEADSET,
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        worn.add(AudioDeviceInfo.TYPE_BLE_HEADSET)
                    }
                    // Output devices are listed from Android 6; before, none counts
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in worn }
                    )
                }
                "openAppSettings" -> {
                    app.startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", app.packageName, null),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EchoStatusService.listen(app, messenger)
        calendar = CalendarBridge(app, messenger)

        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }
}
