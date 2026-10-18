package com.selfie.mirroring.mirroring

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
    }

    private val METHOD_CHANNEL = "com.selfie.mirroring/screen_mirror"
    private val FRAME_CHANNEL = "com.selfie.mirroring/screen_frames"
    private val REQUEST_MEDIA_PROJECTION = 9902

    private var pendingResult: MethodChannel.Result? = null
    private var frameMessageChannel: BasicMessageChannel<Any>? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // StandardMessageCodec transfers ByteArray directly to Dart Uint8List without direct buffer issues
        frameMessageChannel = BasicMessageChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FRAME_CHANNEL,
            io.flutter.plugin.common.StandardMessageCodec.INSTANCE
        )

        // Listen for frames from ScreenCaptureService and forward to Flutter
        ScreenCaptureService.onFrameCaptured = { jpegBytes ->
            mainHandler.post {
                frameMessageChannel?.send(jpegBytes)
            }
        }

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)

        ScreenCaptureService.onCaptureStopped = {
            mainHandler.post {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                try {
                    methodChannel.invokeMethod("onCaptureStopped", null)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to invoke onCaptureStopped: ${e.message}")
                }
            }
        }

        ScreenCaptureService.onCaptureStarted = {
            mainHandler.post {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                try {
                    methodChannel.invokeMethod("onCaptureStarted", null)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to invoke onCaptureStarted: ${e.message}")
                }
            }
        }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScreenMirror" -> {
                    Log.e(TAG, "MethodChannel: startScreenMirror requested")
                    if (ScreenCaptureService.isServiceRunning) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    val captureIntent = mpManager.createScreenCaptureIntent()
                    startActivityForResult(captureIntent, REQUEST_MEDIA_PROJECTION)
                }
                "stopScreenMirror" -> {
                    Log.e(TAG, "MethodChannel: stopScreenMirror requested")
                    val intent = Intent(this, ScreenCaptureService::class.java).apply {
                        action = ScreenCaptureService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                "isMirroring" -> {
                    result.success(ScreenCaptureService.isServiceRunning)
                }
                "openCameraApp" -> {
                    try {
                        val launchIntent = packageManager.getLaunchIntentForPackage("com.sec.android.app.camera")
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            val cameraIntent = Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(cameraIntent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to open camera app: ${e.message}")
                        result.error("CAMERA_ERROR", e.message, null)
                    }
                }
                "triggerCameraShutter" -> {
                    if (CameraAccessibilityService.isServiceRunning()) {
                        val clicked = CameraAccessibilityService.triggerShutter()
                        Log.i(TAG, "triggerCameraShutter via Accessibility: $clicked")
                        result.success(clicked)
                    } else {
                        Log.w(TAG, "CameraAccessibilityService not running! Falling back to volume key")
                        sendVolumeDownKey()
                        result.success(false)
                    }
                }
                "isAccessibilityEnabled" -> {
                    result.success(CameraAccessibilityService.isServiceRunning())
                }
                "openAccessibilitySettings" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null)
                    }
                }
                "minimizeToHome" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        Log.e(TAG, "onActivityResult: requestCode=$requestCode, resultCode=$resultCode, data=$data")

        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // Save token in memory
                ScreenCaptureService.savedResultCode = resultCode
                ScreenCaptureService.savedResultData = data

                val serviceIntent = Intent(this, ScreenCaptureService::class.java).apply {
                    action = ScreenCaptureService.ACTION_START
                    putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(ScreenCaptureService.EXTRA_DATA, data)
                }

                ContextCompat.startForegroundService(this, serviceIntent)
                Log.e(TAG, "startForegroundService called successfully")

                pendingResult?.success(true)
                pendingResult = null
            } else {
                Log.e(TAG, "Permission denied by user in dialog")
                pendingResult?.error("DENIED", "Screen capture permission was denied by user", null)
                pendingResult = null
            }
        }
    }

    private fun sendVolumeDownKey() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_DOWN))
            audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_VOLUME_DOWN))
        } catch (e: Exception) {
            Log.e(TAG, "Error sending volume key: ${e.message}")
        }
    }
}
