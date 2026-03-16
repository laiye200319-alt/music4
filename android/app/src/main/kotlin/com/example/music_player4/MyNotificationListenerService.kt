package com.example.music_player4

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class MyNotificationListenerService : NotificationListenerService() {
    // This service doesn't need to do much for our use-case.
    // Its presence and enabled notification access allow the app to call
    // MediaSessionManager.getActiveSessions(ComponentName).
    
    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.d("MyNotificationListener", "Notification listener connected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        Log.d("MyNotificationListener", "Notification posted: ${sbn?.packageName}")
    }
}