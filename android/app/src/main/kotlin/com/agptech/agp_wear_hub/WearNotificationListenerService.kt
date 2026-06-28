package com.agptech.agp_wear_hub

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.Locale

class WearNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val TAG = "WearNotifListener"

        fun requestRebindIfSupported(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    val component = ComponentName(context, WearNotificationListenerService::class.java)
                    requestRebind(component)
                    Log.d(TAG, "requestRebind invoked")
                } catch (e: Exception) {
                    Log.e(TAG, "requestRebind failed", e)
                }
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.d(TAG, "onListenerConnected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.d(TAG, "onListenerDisconnected")
        requestRebindIfSupported(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            val plugin = QcSdkPlugin.getActiveInstance() ?: return
            if (sbn.packageName == packageName) return
            val n = sbn.notification ?: return
            val extras = n.extras ?: return
            val title = extras.getCharSequence("android.title")?.toString()
            val text = extras.getCharSequence("android.text")?.toString()
            val category = n.category ?: ""
            val packageName = sbn.packageName ?: ""
            val lowerText = listOfNotNull(title, text)
                .joinToString(" ")
                .lowercase(Locale.ROOT)

            val isCall = category == "call" ||
                packageName.contains("dialer", ignoreCase = true) ||
                packageName.contains("telecom", ignoreCase = true) ||
                packageName.contains("phone", ignoreCase = true) ||
                lowerText.contains("incoming call") ||
                lowerText.contains("apel")

            Log.d(TAG, "notif posted: pkg=$packageName category=$category title=$title")

            if (isCall) {
                plugin.pushIncomingCallNotification(title, text)
            } else {
                plugin.pushIncomingMessageNotification(title, text)
            }
        } catch (e: Exception) {
            Log.e(TAG, "onNotificationPosted failed", e)
        }
    }
}
