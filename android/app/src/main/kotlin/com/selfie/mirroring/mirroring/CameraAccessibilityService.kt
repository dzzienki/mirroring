package com.selfie.mirroring.mirroring

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class CameraAccessibilityService : AccessibilityService() {

    companion object {
        const val TAG = "CameraAccessibility"
        var instance: CameraAccessibilityService? = null

        fun isServiceRunning(): Boolean = instance != null

        fun triggerShutter(): Boolean {
            return instance?.performShutterClick() ?: false
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "CameraAccessibilityService connected successfully!")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
        Log.i(TAG, "CameraAccessibilityService destroyed")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Intentionally left blank - event listening not needed
    }

    override fun onInterrupt() {
        Log.w(TAG, "CameraAccessibilityService interrupted")
    }

    fun performShutterClick(): Boolean {
        Log.d(TAG, "performShutterClick requested")

        // 1. First attempt: Find shutter area in Samsung Camera UI node tree
        try {
            val root = rootInActiveWindow
            if (root != null) {
                // Samsung native camera shutter view ID
                val shutterAreaNodes = root.findAccessibilityNodeInfosByViewId("com.sec.android.app.camera:id/shutter_area")
                if (shutterAreaNodes.isNotEmpty()) {
                    val rect = Rect()
                    shutterAreaNodes[0].getBoundsInScreen(rect)
                    if (!rect.isEmpty && rect.width() > 0 && rect.height() > 0) {
                        val cx = rect.centerX().toFloat()
                        val cy = rect.centerY().toFloat()
                        Log.i(TAG, "Found shutter_area at bounds: $rect, tapping ($cx, $cy)")
                        return dispatchTap(cx, cy)
                    }
                }

                val buttonNodes = root.findAccessibilityNodeInfosByViewId("com.sec.android.app.camera:id/bottom_shutter_button")
                if (buttonNodes.isNotEmpty()) {
                    val rect = Rect()
                    buttonNodes[0].getBoundsInScreen(rect)
                    if (!rect.isEmpty && rect.width() > 0 && rect.height() > 0) {
                        val cx = rect.centerX().toFloat()
                        val cy = rect.centerY().toFloat()
                        Log.i(TAG, "Found bottom_shutter_button at bounds: $rect, tapping ($cx, $cy)")
                        return dispatchTap(cx, cy)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error finding shutter node: ${e.message}")
        }

        // 2. Fallback attempt: Tap at bottom center (82.9% height) where Samsung Camera shutter is located
        val metrics = resources.displayMetrics
        val targetX = metrics.widthPixels / 2f
        val targetY = metrics.heightPixels * 0.829f

        Log.i(TAG, "Dispatching tap gesture at standard shutter location ($targetX, $targetY)")
        return dispatchTap(targetX, targetY)
    }

    private fun dispatchTap(x: Float, y: Float): Boolean {
        val path = Path().apply {
            moveTo(x, y)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, 50)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                super.onCompleted(gestureDescription)
                Log.i(TAG, "Shutter tap gesture COMPLETED at ($x, $y)!")
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                super.onCancelled(gestureDescription)
                Log.w(TAG, "Shutter tap gesture CANCELLED at ($x, $y)")
            }
        }, null)
    }
}
