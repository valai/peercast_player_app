package jp.peercast.peercast_app

import android.os.Build
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        if (hasFocus && fullscreen) hideSystemBars()
    }
}
