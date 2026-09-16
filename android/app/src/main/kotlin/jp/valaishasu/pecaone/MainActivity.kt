package jp.valaishasu.pecaone

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.Manifest
import android.app.KeyguardManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.util.Rational
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var fullscreen = false
    private var previousCutoutMode = 0
    private var previousVisibility = 0
    private var playbackChannel: MethodChannel? = null
    private var pipReady = false
    private var pipRatio = Rational(16, 9)
    private val pipLifecycle = PipLifecycle()
    private val handler = Handler(Looper.getMainLooper())
    private var startResult: MethodChannel.Result? = null

    private fun pipSupported() = Build.VERSION.SDK_INT >= 26 &&
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun locked() = getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun updatePip() {
        if (!pipSupported()) return
        val params = PictureInPictureParams.Builder().setAspectRatio(pipRatio)
        if (Build.VERSION.SDK_INT >= 31) params.setAutoEnterEnabled(pipReady && PlaybackService.running)
        setPictureInPictureParams(params.build())
    }

    private fun enterPip(): Boolean {
        if (!pipSupported() || !pipReady || !PlaybackService.running || locked()) return false
        return try {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(pipRatio).build())
        } catch (_: Exception) { false }
    }

    private fun stopPlayback() {
        pipReady = false
        updatePip()
        playbackChannel?.invokeMethod("stop", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "peercast/playback")
        PlaybackService.onStop = { stopPlayback() }
        PlaybackService.onLost = {
            pipReady = false
            updatePip()
            playbackChannel?.invokeMethod("serviceLost", null)
        }
        playbackChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pipSupported" -> result.success(pipSupported())
                "start" -> {
                    pipLifecycle.resetSession()
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7144)
                    }
                    startResult?.success(false)
                    startResult = result
                    PlaybackService.onStarted = { success ->
                        startResult?.success(success)
                        startResult = null
                    }
                    try {
                        val intent = Intent(this, PlaybackService::class.java)
                            .putExtra("title", call.arguments as? String)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        handler.postDelayed({
                            if (startResult === result) {
                                startResult?.success(false)
                                startResult = null
                                PlaybackService.onStarted = null
                                stopService(Intent(this, PlaybackService::class.java))
                            }
                        }, 4000)
                    } catch (_: Exception) {
                        startResult?.success(false)
                        startResult = null
                        PlaybackService.onStarted = null
                    }
                }
                "configure" -> {
                    pipReady = call.argument<Boolean>("playing") == true
                    val ratio = (call.argument<Number>("aspectRatio")?.toDouble() ?: (16.0 / 9))
                        .coerceIn(1.0 / 2.39, 2.39)
                    pipRatio = Rational((ratio * 10000).toInt(), 10000)
                    updatePip()
                    result.success(null)
                }
                "enterPip" -> result.success(enterPip())
                "stop" -> {
                    pipLifecycle.resetSession()
                    pipReady = false
                    updatePip()
                    startResult?.success(false)
                    startResult = null
                    PlaybackService.onStarted = null
                    // Expected shutdown must not send a serviceLost event to a newer session.
                    PlaybackService.intentionalStop = true
                    stopService(Intent(this, PlaybackService::class.java))
                    result.success(null)
                    if (Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode) {
                        // Do not leave an empty PiP window showing the channel directory.
                        handler.post { finish() }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "peercast_app/runtime")
            .setMethodCallHandler { call, result ->
                if (call.method == "isEmulator") {
                    result.success(
                        Build.HARDWARE == "goldfish" || Build.HARDWARE == "ranchu" ||
                            Build.FINGERPRINT.startsWith("generic/sdk") ||
                            Build.FINGERPRINT.startsWith("google/sdk_gphone")
                    )
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "peercast/display")
            .setMethodCallHandler { call, result ->
                if (call.method == "setFullscreen") {
                    setFullscreen(call.arguments == true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun setFullscreen(enabled: Boolean) {
        if (fullscreen == enabled) return
        if (enabled) {
            previousVisibility = window.decorView.systemUiVisibility
            if (Build.VERSION.SDK_INT >= 28) {
                previousCutoutMode = window.attributes.layoutInDisplayCutoutMode
            }
        }
        fullscreen = enabled
        if (Build.VERSION.SDK_INT >= 28) {
            val attributes = window.attributes
            attributes.layoutInDisplayCutoutMode = if (enabled) {
                if (Build.VERSION.SDK_INT >= 30) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            } else {
                previousCutoutMode
            }
            window.attributes = attributes
        }
        if (enabled) {
            hideSystemBars()
        } else if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.show(WindowInsets.Type.systemBars())
        } else {
            window.decorView.systemUiVisibility = previousVisibility
        }
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.apply {
                systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsets.Type.systemBars())
            }
        } else {
            window.decorView.systemUiVisibility =
                previousVisibility or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && fullscreen && !pipLifecycle.inPip) hideSystemBars()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipReady && !locked()) {
            if (Build.VERSION.SDK_INT < 31) {
                if (!enterPip()) playbackChannel?.invokeMethod("pipFailed", null)
            } else {
                handler.postDelayed({
                    if (!pipLifecycle.resumed && !isInPictureInPictureMode && !locked() && pipReady) {
                        playbackChannel?.invokeMethod("pipFailed", null)
                    }
                }, 700)
            }
        }
    }

    override fun onStart() {
        pipLifecycle.onStart()
        super.onStart()
    }

    override fun onResume() {
        pipLifecycle.onResume()
        super.onResume()
    }

    override fun onPause() {
        pipLifecycle.onPause()
        super.onPause()
    }

    private fun checkPipClosed(ticket: Int) {
        handler.postDelayed({
            if (pipReady && pipLifecycle.shouldStop(ticket, locked(),
                    getSystemService(PowerManager::class.java).isInteractive)) {
                stopPlayback()
            }
        }, 500)
    }

    override fun onStop() {
        val dismissal = pipLifecycle.onStop()
        super.onStop()
        if (dismissal != null) checkPipClosed(dismissal)
    }

    override fun onPictureInPictureModeChanged(inPip: Boolean, config: Configuration) {
        super.onPictureInPictureModeChanged(inPip, config)
        pipLifecycle.onPipChanged(inPip)
        playbackChannel?.invokeMethod("pipChanged", inPip)
        // Expanding the window can precede onResume by more than an animation frame.
        // Never infer a close from this callback; an actual onStop is required.
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        startResult?.success(false)
        startResult = null
        PlaybackService.onStarted = null
        PlaybackService.onStop = null
        PlaybackService.onLost = null
        stopService(Intent(this, PlaybackService::class.java))
        playbackChannel?.setMethodCallHandler(null)
        playbackChannel = null
        super.onDestroy()
    }
}
