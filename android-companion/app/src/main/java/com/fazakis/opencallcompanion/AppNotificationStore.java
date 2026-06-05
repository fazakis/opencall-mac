package com.fazakis.opencallcompanion;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.provider.Settings;
import android.service.notification.StatusBarNotification;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Set;

final class AppNotificationStore {
    static final String INSTAGRAM_PACKAGE = "com.instagram.android";
    static final String VIBER_PACKAGE = "com.viber.voip";
    static final String MESSENGER_PACKAGE = "com.facebook.orca";
    private static final Set<String> WATCHED_PACKAGES = new HashSet<>(Arrays.asList(INSTAGRAM_PACKAGE, VIBER_PACKAGE, MESSENGER_PACKAGE));
    private static final String PREFS = "app_notifications";
    private static final String KEY_ITEMS = "items";
    private static final int MAX_STORED = 120;

    private AppNotificationStore() {}

    static boolean isWatchedPackage(String packageName) {
        return WATCHED_PACKAGES.contains(packageName);
    }

    static JSONArray watchedPackages() {
        JSONArray array = new JSONArray();
        array.put(INSTAGRAM_PACKAGE);
        array.put(VIBER_PACKAGE);
        array.put(MESSENGER_PACKAGE);
        return array;
    }

    static boolean isNotificationListenerEnabled(Context context) {
        try {
            String flat = Settings.Secure.getString(context.getContentResolver(), "enabled_notification_listeners");
            if (flat == null || flat.trim().isEmpty()) return false;
            String packageName = context.getPackageName();
            for (String part : flat.split(":")) {
                ComponentName component = ComponentName.unflattenFromString(part);
                if (component != null && packageName.equals(component.getPackageName())) return true;
            }
        } catch (Exception ignored) {}
        return false;
    }

    static void record(Context context, StatusBarNotification sbn) {
        if (sbn == null || !isWatchedPackage(sbn.getPackageName())) return;
        Notification n = sbn.getNotification();
        if (n == null) return;
        if ((n.flags & Notification.FLAG_ONGOING_EVENT) != 0) return;

        Bundle extras = n.extras == null ? Bundle.EMPTY : n.extras;
        String title = clean(charSequence(extras.getCharSequence(Notification.EXTRA_TITLE)));
        String text = clean(firstNonEmpty(
                charSequence(extras.getCharSequence(Notification.EXTRA_BIG_TEXT)),
                charSequence(extras.getCharSequence(Notification.EXTRA_TEXT)),
                joinLines(extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES))));
        String subText = clean(charSequence(extras.getCharSequence(Notification.EXTRA_SUB_TEXT)));
        if (title.isEmpty() && text.isEmpty() && subText.isEmpty()) return;

        try {
            JSONObject item = new JSONObject();
            item.put("id", stableId(sbn));
            item.put("key", safe(sbn.getKey()));
            item.put("packageName", sbn.getPackageName());
            item.put("appName", appLabel(context, sbn.getPackageName()));
            item.put("title", trim(title, 240));
            item.put("text", trim(text, 700));
            item.put("subText", trim(subText, 240));
            item.put("date", sbn.getPostTime() > 0 ? sbn.getPostTime() : System.currentTimeMillis());
            item.put("clearable", sbn.isClearable());
            item.put("group", safe(sbn.getGroupKey()));
            add(context, item);
        } catch (Exception ignored) {}
    }

    static JSONObject list(Context context, int limit) throws Exception {
        JSONArray stored = load(context);
        JSONArray outItems = new JSONArray();
        int max = Math.max(1, Math.min(limit, MAX_STORED));
        for (int i = 0; i < stored.length() && outItems.length() < max; i++) {
            JSONObject item = stored.optJSONObject(i);
            if (item != null) outItems.put(item);
        }
        JSONObject out = new JSONObject();
        out.put("ok", true);
        out.put("listenerEnabled", isNotificationListenerEnabled(context));
        out.put("watchedPackages", watchedPackages());
        out.put("notifications", outItems);
        out.put("count", outItems.length());
        return out;
    }

    private static synchronized void add(Context context, JSONObject item) throws Exception {
        JSONArray existing = load(context);
        LinkedHashMap<String, JSONObject> byId = new LinkedHashMap<>();
        String newId = item.optString("id", "");
        if (!newId.isEmpty()) byId.put(newId, item);
        for (int i = 0; i < existing.length() && byId.size() < MAX_STORED; i++) {
            JSONObject old = existing.optJSONObject(i);
            if (old == null) continue;
            String id = old.optString("id", "");
            if (!id.isEmpty() && !byId.containsKey(id)) byId.put(id, old);
        }
        JSONArray saved = new JSONArray();
        for (JSONObject value : byId.values()) saved.put(value);
        prefs(context).edit().putString(KEY_ITEMS, saved.toString()).apply();
    }

    private static JSONArray load(Context context) {
        try {
            return new JSONArray(prefs(context).getString(KEY_ITEMS, "[]"));
        } catch (Exception e) {
            return new JSONArray();
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String stableId(StatusBarNotification sbn) {
        String key = safe(sbn.getKey());
        if (!key.isEmpty()) return key;
        return sbn.getPackageName() + ":" + sbn.getId() + ":" + sbn.getPostTime();
    }

    private static String appLabel(Context context, String packageName) {
        if (INSTAGRAM_PACKAGE.equals(packageName)) return "Instagram";
        if (VIBER_PACKAGE.equals(packageName)) return "Viber";
        if (MESSENGER_PACKAGE.equals(packageName)) return "Messenger";
        try {
            PackageManager pm = context.getPackageManager();
            return String.valueOf(pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)));
        } catch (Exception ignored) {
            return packageName;
        }
    }

    private static String firstNonEmpty(String... values) {
        for (String value : values) {
            if (value != null && !value.trim().isEmpty()) return value;
        }
        return "";
    }

    private static String joinLines(CharSequence[] lines) {
        if (lines == null || lines.length == 0) return "";
        StringBuilder sb = new StringBuilder();
        for (CharSequence line : lines) {
            String text = charSequence(line).trim();
            if (text.isEmpty()) continue;
            if (sb.length() > 0) sb.append("\n");
            sb.append(text);
        }
        return sb.toString();
    }

    private static String charSequence(CharSequence cs) {
        return cs == null ? "" : cs.toString();
    }

    private static String clean(String value) {
        return safe(value).replace('\r', ' ').trim();
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static String trim(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, Math.max(0, max - 1)) + "…";
    }
}
