package com.fazakis.opencallcompanion;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CallLog;
import android.provider.ContactsContract;
import android.provider.Telephony;
import android.telephony.SmsManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

final class DataProvider {
    private final Context context;

    DataProvider(Context context) {
        this.context = context.getApplicationContext();
    }

    boolean hasPermission(String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    JSONObject contacts() throws Exception {
        require(Manifest.permission.READ_CONTACTS);
        LinkedHashMap<String, JSONObject> byContact = new LinkedHashMap<>();
        Uri uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI;
        String[] projection = new String[] {
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE,
                ContactsContract.CommonDataKinds.Phone.LABEL
        };
        try (Cursor c = context.getContentResolver().query(
                uri, projection, null, null,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE LOCALIZED ASC")) {
            if (c != null) {
                while (c.moveToNext()) {
                    String id = value(c, ContactsContract.CommonDataKinds.Phone.CONTACT_ID);
                    String name = value(c, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME);
                    String number = value(c, ContactsContract.CommonDataKinds.Phone.NUMBER);
                    int type = intValue(c, ContactsContract.CommonDataKinds.Phone.TYPE);
                    String customLabel = value(c, ContactsContract.CommonDataKinds.Phone.LABEL);
                    String label = (String) ContactsContract.CommonDataKinds.Phone.getTypeLabel(
                            context.getResources(), type, customLabel);
                    if (number == null || number.trim().isEmpty()) continue;
                    JSONObject contact = byContact.get(id);
                    if (contact == null) {
                        contact = new JSONObject();
                        contact.put("id", id == null ? name : id);
                        contact.put("name", name == null ? "" : name);
                        contact.put("numbers", new JSONArray());
                        byContact.put(id == null ? name + number : id, contact);
                    }
                    JSONObject n = new JSONObject();
                    n.put("label", label == null ? "" : label);
                    n.put("number", number);
                    contact.getJSONArray("numbers").put(n);
                }
            }
        }
        JSONArray contacts = new JSONArray();
        for (Map.Entry<String, JSONObject> entry : byContact.entrySet()) contacts.put(entry.getValue());
        JSONObject out = ok();
        out.put("contacts", contacts);
        out.put("count", contacts.length());
        return out;
    }

    JSONObject calls(int limit) throws Exception {
        require(Manifest.permission.READ_CALL_LOG);
        JSONArray calls = new JSONArray();
        String[] projection = new String[] {
                CallLog.Calls._ID,
                CallLog.Calls.NUMBER,
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION
        };
        try (Cursor c = context.getContentResolver().query(
                CallLog.Calls.CONTENT_URI, projection, null, null,
                CallLog.Calls.DATE + " DESC")) {
            if (c != null) {
                int count = 0;
                while (c.moveToNext() && count < limit) {
                    JSONObject item = new JSONObject();
                    item.put("id", value(c, CallLog.Calls._ID));
                    item.put("number", value(c, CallLog.Calls.NUMBER));
                    item.put("name", value(c, CallLog.Calls.CACHED_NAME));
                    item.put("type", callType(intValue(c, CallLog.Calls.TYPE)));
                    item.put("date", longValue(c, CallLog.Calls.DATE));
                    item.put("duration", longValue(c, CallLog.Calls.DURATION));
                    calls.put(item);
                    count++;
                }
            }
        }
        JSONObject out = ok();
        out.put("calls", calls);
        out.put("count", calls.length());
        return out;
    }

    JSONObject sms(int limit) throws Exception {
        require(Manifest.permission.READ_SMS);
        JSONArray messages = new JSONArray();
        Uri uri = Telephony.Sms.CONTENT_URI;
        String[] projection = new String[] {
                Telephony.Sms._ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ
        };
        try (Cursor c = context.getContentResolver().query(
                uri, projection, null, null,
                Telephony.Sms.DATE + " DESC")) {
            if (c != null) {
                int count = 0;
                while (c.moveToNext() && count < limit) {
                    JSONObject item = new JSONObject();
                    item.put("id", value(c, Telephony.Sms._ID));
                    item.put("address", value(c, Telephony.Sms.ADDRESS));
                    item.put("body", value(c, Telephony.Sms.BODY));
                    item.put("date", longValue(c, Telephony.Sms.DATE));
                    item.put("type", smsType(intValue(c, Telephony.Sms.TYPE)));
                    item.put("read", intValue(c, Telephony.Sms.READ) == 1);
                    messages.put(item);
                    count++;
                }
            }
        }
        JSONObject out = ok();
        out.put("messages", messages);
        out.put("count", messages.length());
        return out;
    }

    JSONObject sendSms(String number, String text) throws Exception {
        require(Manifest.permission.SEND_SMS);
        String cleanNumber = number == null ? "" : number.trim();
        String body = text == null ? "" : text.trim();
        if (cleanNumber.isEmpty()) throw new IllegalArgumentException("Missing number");
        if (body.isEmpty()) throw new IllegalArgumentException("Missing message text");
        SmsManager manager = context.getSystemService(SmsManager.class);
        if (manager == null) manager = SmsManager.getDefault();
        java.util.ArrayList<String> parts = manager.divideMessage(body);
        if (parts == null || parts.isEmpty()) {
            manager.sendTextMessage(cleanNumber, null, body, null, null);
        } else {
            manager.sendMultipartTextMessage(cleanNumber, null, parts, null, null);
        }
        JSONObject out = ok();
        out.put("sent", true);
        out.put("number", cleanNumber);
        out.put("parts", parts == null || parts.isEmpty() ? 1 : parts.size());
        return out;
    }

    JSONObject callState() throws Exception {
        require(Manifest.permission.READ_PHONE_STATE);
        return OpenCallCompanionService.callStateTracker(context).snapshot();
    }

    JSONObject health(String token, boolean running, int port, boolean bluetoothRunning, boolean bleRunning, String bleError) throws Exception {
        JSONObject out = ok();
        out.put("service", "OpenCall Companion");
        out.put("version", 5);
        out.put("running", running);
        out.put("port", port);
        out.put("bluetoothRunning", bluetoothRunning || bleRunning);
        out.put("classicBluetoothRunning", bluetoothRunning);
        out.put("bleRunning", bleRunning);
        out.put("bleMode", OpenCallCompanionService.bleMetaServer(context).advertiseModeName());
        out.put("bleLastMacSeenAt", OpenCallCompanionService.bleMetaServer(context).lastMacSeenAt());
        out.put("bleError", bleError == null ? JSONObject.NULL : bleError);
        out.put("bluetoothUuid", BluetoothMetaServer.SERVICE_UUID.toString());
        out.put("bleCharacteristicUuid", BleMetaServer.CHARACTERISTIC_UUID.toString());
        out.put("tokenLength", token == null ? 0 : token.length());
        JSONArray missing = new JSONArray();
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) missing.put("READ_CONTACTS");
        if (!hasPermission(Manifest.permission.READ_SMS)) missing.put("READ_SMS");
        if (!hasPermission(Manifest.permission.SEND_SMS)) missing.put("SEND_SMS");
        if (!hasPermission(Manifest.permission.READ_CALL_LOG)) missing.put("READ_CALL_LOG");
        if (!hasPermission(Manifest.permission.READ_PHONE_STATE)) missing.put("READ_PHONE_STATE");
        if (android.os.Build.VERSION.SDK_INT >= 31 && !hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) missing.put("BLUETOOTH_CONNECT");
        if (android.os.Build.VERSION.SDK_INT >= 31 && !hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)) missing.put("BLUETOOTH_ADVERTISE");
        out.put("missingPermissions", missing);
        return out;
    }

    private JSONObject ok() throws Exception {
        JSONObject out = new JSONObject();
        out.put("ok", true);
        return out;
    }

    private void require(String permission) throws SecurityException {
        if (!hasPermission(permission)) throw new SecurityException("Missing permission: " + permission);
    }

    private static String value(Cursor c, String column) {
        int idx = c.getColumnIndex(column);
        if (idx < 0 || c.isNull(idx)) return "";
        return c.getString(idx);
    }

    private static int intValue(Cursor c, String column) {
        int idx = c.getColumnIndex(column);
        if (idx < 0 || c.isNull(idx)) return 0;
        return c.getInt(idx);
    }

    private static long longValue(Cursor c, String column) {
        int idx = c.getColumnIndex(column);
        if (idx < 0 || c.isNull(idx)) return 0L;
        return c.getLong(idx);
    }

    private static String callType(int type) {
        switch (type) {
            case CallLog.Calls.INCOMING_TYPE: return "incoming";
            case CallLog.Calls.OUTGOING_TYPE: return "outgoing";
            case CallLog.Calls.MISSED_TYPE: return "missed";
            case CallLog.Calls.VOICEMAIL_TYPE: return "voicemail";
            case CallLog.Calls.REJECTED_TYPE: return "rejected";
            case CallLog.Calls.BLOCKED_TYPE: return "blocked";
            case CallLog.Calls.ANSWERED_EXTERNALLY_TYPE: return "answered_externally";
            default: return "unknown";
        }
    }

    private static String smsType(int type) {
        switch (type) {
            case Telephony.Sms.MESSAGE_TYPE_INBOX: return "inbox";
            case Telephony.Sms.MESSAGE_TYPE_SENT: return "sent";
            case Telephony.Sms.MESSAGE_TYPE_DRAFT: return "draft";
            case Telephony.Sms.MESSAGE_TYPE_OUTBOX: return "outbox";
            case Telephony.Sms.MESSAGE_TYPE_FAILED: return "failed";
            case Telephony.Sms.MESSAGE_TYPE_QUEUED: return "queued";
            default: return "unknown";
        }
    }
}
