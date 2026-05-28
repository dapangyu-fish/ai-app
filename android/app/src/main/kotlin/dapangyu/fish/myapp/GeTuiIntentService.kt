package dapangyu.fish.myapp

import android.content.Context
import android.util.Log
import com.igexin.sdk.GTIntentService
import com.igexin.sdk.message.GTNotificationMessage
import com.igexin.sdk.message.GTTransmitMessage

class GeTuiIntentService : GTIntentService() {
    override fun onReceiveServicePid(context: Context?, pid: Int) {
        Log.d("MyAppGeTui", "service pid=$pid")
    }

    override fun onReceiveClientId(context: Context?, clientId: String?) {
        if (!clientId.isNullOrBlank()) {
            GeTuiBridge.emit("onReceiveClientId", clientId)
        }
    }

    override fun onReceiveOnlineState(context: Context?, online: Boolean) {
        GeTuiBridge.emit("onReceiveOnlineState", online)
    }

    override fun onReceiveMessageData(context: Context?, msg: GTTransmitMessage?) {
        if (msg == null) return
        GeTuiBridge.emit(
            "onReceivePayload",
            mapOf(
                "messageId" to msg.messageId,
                "payloadId" to msg.payloadId,
                "taskId" to msg.taskId,
                "payload" to String(msg.payload ?: ByteArray(0)),
            ),
        )
    }

    override fun onNotificationMessageArrived(context: Context?, message: GTNotificationMessage?) {
        GeTuiBridge.emit("onNotificationMessageArrived", notificationToMap(message))
    }

    override fun onNotificationMessageClicked(context: Context?, message: GTNotificationMessage?) {
        GeTuiBridge.emit("onNotificationMessageClicked", notificationToMap(message))
    }

    private fun notificationToMap(message: GTNotificationMessage?): Map<String, Any?> {
        if (message == null) return emptyMap()
        val result = linkedMapOf<String, Any?>()
        for (method in message.javaClass.methods) {
            if (method.parameterTypes.isNotEmpty() || !method.name.startsWith("get")) continue
            val key = method.name.removePrefix("get").replaceFirstChar { it.lowercaseChar() }
            if (key == "class") continue
            runCatching {
                val value = method.invoke(message)
                if (value == null || value is String || value is Number || value is Boolean) {
                    result[key] = value
                } else {
                    result[key] = value.toString()
                }
            }
        }
        return result
    }
}
