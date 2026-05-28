package dapangyu.fish.myapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.igexin.sdk.PushManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object GeTuiBridge {
    private const val TAG = "MyAppGeTui"
    private const val CHANNEL = "dapangyu.fish.myapp/getui"

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        appContext = context.applicationContext
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> result.success(init())
            "getClientId" -> result.success(clientId())
            "turnOnPush" -> {
                appContext?.let { PushManager.getInstance().turnOnPush(it) }
                result.success(true)
            }
            "turnOffPush" -> {
                appContext?.let { PushManager.getInstance().turnOffPush(it) }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun init(): Boolean {
        val context = appContext ?: return false
        return try {
            PushManager.getInstance().registerPushIntentService(context, GeTuiIntentService::class.java)
            PushManager.getInstance().initialize(context, GeTuiPushService::class.java)
            Log.i(TAG, "GeTui SDK initialized")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "GeTui initialize failed, retry with privacy strategy", e)
            try {
                val method = PushManager::class.java.getDeclaredMethod(
                    "setPrivacyPolicyStrategy",
                    Context::class.java,
                    java.lang.Boolean.TYPE,
                )
                method.invoke(PushManager.getInstance(), context, true)
                PushManager.getInstance().registerPushIntentService(context, GeTuiIntentService::class.java)
                PushManager.getInstance().initialize(context, GeTuiPushService::class.java)
                true
            } catch (retryError: Throwable) {
                Log.e(TAG, "GeTui initialize retry failed", retryError)
                false
            }
        }
    }

    private fun clientId(): String {
        val context = appContext ?: return ""
        return try {
            PushManager.getInstance().getClientid(context) ?: ""
        } catch (e: Throwable) {
            Log.w(TAG, "getClientId failed", e)
            ""
        }
    }

    fun emit(method: String, payload: Any?) {
        mainHandler.post {
            channel?.invokeMethod(method, payload)
        }
    }
}
