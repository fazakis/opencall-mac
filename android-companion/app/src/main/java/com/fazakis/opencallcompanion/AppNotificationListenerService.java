package com.fazakis.opencallcompanion;

import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

public class AppNotificationListenerService extends NotificationListenerService {
    @Override public void onListenerConnected() {
        recordActiveNotifications();
    }

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        AppNotificationStore.record(this, sbn);
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        // Keep a short history for the Mac poller even after Android clears it.
    }

    private void recordActiveNotifications() {
        try {
            StatusBarNotification[] active = getActiveNotifications();
            if (active == null) return;
            for (StatusBarNotification notification : active) {
                AppNotificationStore.record(this, notification);
            }
        } catch (Exception ignored) {}
    }
}
