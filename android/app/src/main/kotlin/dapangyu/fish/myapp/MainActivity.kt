package dapangyu.fish.myapp

import android.graphics.Rect
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.dapangyu.fish/gesture_exclusion"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setGestureExclusionRects" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val rects = call.argument<List<Map<String, Int>>>("rects")
                            if (rects != null) {
                                val exclusionRects = rects.map { map ->
                                    Rect(
                                        map["left"] ?: 0,
                                        map["top"] ?: 0,
                                        map["right"] ?: 0,
                                        map["bottom"] ?: 0
                                    )
                                }
                                window.decorView.systemGestureExclusionRects = exclusionRects
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } else {
                            // API < 29, no system gesture exclusion support
                            result.success(false)
                        }
                    }
                    "clearGestureExclusionRects" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            window.decorView.systemGestureExclusionRects = emptyList()
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
