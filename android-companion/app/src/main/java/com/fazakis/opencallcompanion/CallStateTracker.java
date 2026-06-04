package com.fazakis.opencallcompanion;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.telephony.PhoneStateListener;
import android.telephony.TelephonyManager;

import org.json.JSONObject;

final class CallStateTracker {
    private final Context context;
    private final TelephonyManager telephony;
    private PhoneStateListener listener;
    private volatile int state = TelephonyManager.CALL_STATE_IDLE;
    private volatile String incomingNumber = "";
    private volatile long updatedAt = 0;
    private volatile boolean listening = false;
    private volatile String lastError = "";

    CallStateTracker(Context context) {
        this.context = context.getApplicationContext();
        this.telephony = this.context.getSystemService(TelephonyManager.class);
    }

    synchronized void start() {
        if (!hasPermission()) {
            listening = false;
            lastError = "Missing permission: READ_PHONE_STATE";
            return;
        }
        if (telephony == null) {
            listening = false;
            lastError = "TelephonyManager unavailable";
            return;
        }
        try {
            state = telephony.getCallState();
            updatedAt = System.currentTimeMillis();
            if (listener == null) {
                listener = new PhoneStateListener() {
                    @Override public void onCallStateChanged(int newState, String phoneNumber) {
                        state = newState;
                        if (phoneNumber != null && !phoneNumber.trim().isEmpty()) incomingNumber = phoneNumber.trim();
                        if (newState == TelephonyManager.CALL_STATE_IDLE) incomingNumber = "";
                        updatedAt = System.currentTimeMillis();
                    }
                };
            }
            telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE);
            listening = true;
            lastError = "";
        } catch (SecurityException se) {
            listening = false;
            lastError = se.getMessage() == null ? "Missing permission: READ_PHONE_STATE" : se.getMessage();
        } catch (Exception ex) {
            listening = false;
            lastError = ex.getClass().getSimpleName() + ": " + ex.getMessage();
        }
    }

    synchronized void stop() {
        if (telephony != null && listener != null) {
            try { telephony.listen(listener, PhoneStateListener.LISTEN_NONE); } catch (Exception ignored) {}
        }
        listening = false;
    }

    JSONObject snapshot() throws Exception {
        if (!hasPermission()) throw new SecurityException("Missing permission: READ_PHONE_STATE");
        start();
        JSONObject out = new JSONObject();
        out.put("ok", true);
        out.put("state", stateName(state));
        out.put("stateCode", state);
        out.put("idle", state == TelephonyManager.CALL_STATE_IDLE);
        out.put("ringing", state == TelephonyManager.CALL_STATE_RINGING);
        out.put("offhook", state == TelephonyManager.CALL_STATE_OFFHOOK);
        out.put("incomingNumber", incomingNumber == null || incomingNumber.isEmpty() ? JSONObject.NULL : incomingNumber);
        out.put("updatedAt", updatedAt);
        out.put("listening", listening);
        out.put("error", lastError == null || lastError.isEmpty() ? JSONObject.NULL : lastError);
        return out;
    }

    private boolean hasPermission() {
        return context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED;
    }

    static String stateName(int state) {
        switch (state) {
            case TelephonyManager.CALL_STATE_RINGING: return "ringing";
            case TelephonyManager.CALL_STATE_OFFHOOK: return "offhook";
            case TelephonyManager.CALL_STATE_IDLE:
            default: return "idle";
        }
    }
}
