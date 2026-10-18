package com.selfie.mirroring.mirroring

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class ScreenCaptureService : Service() {

    companion object {
        const val TAG = "ScreenCaptureService"
        const val CHANNEL_ID = "ScreenMirrorChannel"
        const val NOTIFICATION_ID = 9901
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_RESULT_CODE = "EXTRA_RESULT_CODE"
        const val EXTRA_DATA = "EXTRA_DATA"

        var onFrameCaptured: ((ByteArray) -> Unit)? = null
        var onCaptureStarted: (() -> Unit)? = null
        var onCaptureStopped: (() -> Unit)? = null
        var isServiceRunning = false

        // In-memory intent fallback to avoid parceling serialization bugs on Android 14+
        var savedResultCode: Int = 0
        var savedResultData: Intent? = null
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private var targetWidth = 512
    private var targetHeight = 1108
    private var densityDpi = 240

    // Reusable buffers to avoid GC pauses at 30-60fps
    private var cleanBuffer: ByteBuffer? = null
    private var paddedBitmap: Bitmap? = null
    private var finalBitmap: Bitmap? = null
    private var cropCanvas: Canvas? = null
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val jpegOutputStream = ByteArrayOutputStream(128 * 1024)

    private var isProcessingFrame = false
    private var frameCounter = 0L
    private var lastFrameTimestampMs = 0L
    private val MIN_FRAME_INTERVAL_MS = 38L // ~26 FPS: super smooth viewfinder, minimal bandwidth (avoids Wi-Fi/socket saturation)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        backgroundThread = HandlerThread("ScreenCaptureThread").apply { start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.d(TAG, "onStartCommand action=$action")

        if (action == ACTION_START) {
            try {
                startForegroundNotification()

                val resultCode = savedResultCode.takeIf { it != 0 }
                    ?: intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
                val data = savedResultData
                    ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent?.getParcelableExtra(EXTRA_DATA)
                    }

                if (resultCode != 0 && data != null) {
                    startCapture(resultCode, data)
                } else {
                    Log.e(TAG, "Missing resultCode or data: resultCode=$resultCode, data=$data")
                    stopSelf()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start capture: ${e.message}", e)
                stopSelf()
            }
        } else if (action == ACTION_STOP) {
            stopCapture()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "무선 셀카 모니터 화면 미러링",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "서브 폰으로 갤럭시 화면을 실시간 전송 중입니다"
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("셀카 모니터 미러링 실행 중")
            .setContentText("삼성 기본 카메라 앱을 열어 자유롭게 촬영하세요")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isServiceRunning = true
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = mpManager.getMediaProjection(resultCode, data)

        if (mediaProjection == null) {
            Log.e(TAG, "getMediaProjection returned null!")
            stopSelf()
            return
        }

        val handler = backgroundHandler ?: Handler(backgroundThread?.looper ?: return)

        // Android 14+ requires registering callback BEFORE creating virtual display!
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                super.onStop()
                Log.d(TAG, "MediaProjection stopped by system")
                stopCapture()
                stopSelf()
            }
        }, handler)

        // Calculate aspect-ratio-matched capture resolution
        val windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(metrics)

        densityDpi = metrics.densityDpi
        val realWidth = metrics.widthPixels
        val realHeight = metrics.heightPixels

        // Use base width 512 for perfect 256-byte row stride alignment (512 * 4 = 2048 bytes, 2048 % 256 == 0)
        targetWidth = 512
        targetHeight = (512.0 * realHeight / realWidth).toInt()
        if (targetHeight % 2 != 0) targetHeight++

        Log.i(TAG, "Screen resolution: ${realWidth}x${realHeight}, capture size: ${targetWidth}x${targetHeight}")

        imageReader = ImageReader.newInstance(targetWidth, targetHeight, PixelFormat.RGBA_8888, 2)
        imageReader?.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener

            val now = android.os.SystemClock.elapsedRealtime()
            if (isProcessingFrame || (now - lastFrameTimestampMs < MIN_FRAME_INTERVAL_MS)) {
                image.close()
                return@setOnImageAvailableListener
            }

            lastFrameTimestampMs = now
            isProcessingFrame = true
            try {
                val planes = image.planes
                val buffer: ByteBuffer = planes[0].buffer
                val pixelStride = planes[0].pixelStride
                val rowStride = planes[0].rowStride
                val rowPadding = rowStride - pixelStride * targetWidth

                if (rowPadding == 0) {
                    // Fast direct zero-copy into finalBitmap
                    if (finalBitmap == null || finalBitmap?.width != targetWidth || finalBitmap?.height != targetHeight) {
                        finalBitmap?.recycle()
                        finalBitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                    }
                    buffer.rewind()
                    finalBitmap!!.copyPixelsFromBuffer(buffer)
                } else {
                    // Safe padded buffer path: guarantees buffer is large enough for copyPixelsFromBuffer
                    val requiredBytes = rowStride * targetHeight
                    if (cleanBuffer == null || cleanBuffer!!.capacity() != requiredBytes) {
                        cleanBuffer = ByteBuffer.allocate(requiredBytes)
                    }
                    cleanBuffer!!.clear()
                    buffer.rewind()
                    cleanBuffer!!.put(buffer)
                    // Pad remaining bytes for the last row with 0s
                    val remaining = cleanBuffer!!.remaining()
                    for (i in 0 until remaining) {
                        cleanBuffer!!.put(0.toByte())
                    }
                    cleanBuffer!!.rewind()

                    val paddedWidth = rowStride / pixelStride
                    if (paddedBitmap == null || paddedBitmap?.width != paddedWidth || paddedBitmap?.height != targetHeight) {
                        paddedBitmap?.recycle()
                        paddedBitmap = Bitmap.createBitmap(paddedWidth, targetHeight, Bitmap.Config.ARGB_8888)
                    }
                    paddedBitmap!!.copyPixelsFromBuffer(cleanBuffer!!)

                    if (finalBitmap == null || finalBitmap?.width != targetWidth || finalBitmap?.height != targetHeight) {
                        finalBitmap?.recycle()
                        finalBitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                        cropCanvas = Canvas(finalBitmap!!)
                    }
                    val srcRect = Rect(0, 0, targetWidth, targetHeight)
                    val dstRect = Rect(0, 0, targetWidth, targetHeight)
                    cropCanvas!!.drawBitmap(paddedBitmap!!, srcRect, dstRect, paint)
                }

                image.close()

                if (finalBitmap != null) {
                    jpegOutputStream.reset()
                    finalBitmap!!.compress(Bitmap.CompressFormat.JPEG, 62, jpegOutputStream)
                    val jpegBytes = jpegOutputStream.toByteArray()

                    frameCounter++
                    if (frameCounter % 60 == 0L) {
                        Log.d(TAG, "Frame #$frameCounter captured, size: ${jpegBytes.size} bytes")
                    }

                    onFrameCaptured?.invoke(jpegBytes)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error encoding frame: ${e.message}", e)
                try { image.close() } catch (_: Exception) {}
            } finally {
                isProcessingFrame = false
            }
        }, handler)

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "SelfieMirrorDisplay",
            targetWidth,
            targetHeight,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            null
        )

        Log.d(TAG, "VirtualDisplay created: ${targetWidth}x${targetHeight}")
        onCaptureStarted?.invoke()
    }

    private fun stopCapture() {
        if (!isServiceRunning && virtualDisplay == null) return
        isServiceRunning = false
        try {
            virtualDisplay?.release()
            virtualDisplay = null
            imageReader?.close()
            imageReader = null
            mediaProjection?.stop()
            mediaProjection = null

            paddedBitmap?.recycle()
            paddedBitmap = null
            finalBitmap?.recycle()
            finalBitmap = null
            cropCanvas = null
            cleanBuffer = null
        } catch (e: Exception) {
            // ignore cleanup errors
        }
        onCaptureStopped?.invoke()
    }

    override fun onDestroy() {
        stopCapture()
        backgroundThread?.quitSafely()
        backgroundThread = null
        backgroundHandler = null
        super.onDestroy()
    }
}
