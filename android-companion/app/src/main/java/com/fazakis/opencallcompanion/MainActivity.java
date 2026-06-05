package com.fazakis.opencallcompanion;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;

public class MainActivity extends Activity {
    static final String ACTION_COPY_INFO = "com.fazakis.opencallcompanion.COPY_INFO";
    private TextView status;
    private LocalHttpServer server;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        server = OpenCallCompanionService.server(this);
        buildUi();
        startService();
        handleIntent(getIntent());
        refreshStatus();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIntent(intent);
        refreshStatus();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        OpenCallCompanionService.bluetoothMetaServer(this).start();
        OpenCallCompanionService.bleMetaServer(this).start();
        refreshStatus();
    }

    @Override protected void onResume() {
        super.onResume();
        startService();
        OpenCallCompanionService.bluetoothMetaServer(this).start();
        OpenCallCompanionService.bleMetaServer(this).start();
        refreshStatus();
    }

    private void handleIntent(Intent intent) {
        if (intent != null && ACTION_COPY_INFO.equals(intent.getAction())) {
            copy(server.localUrl() + "\nToken: " + server.token());
        }
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 32, 32, 32);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("OpenCall Companion");
        title.setTextSize(24);
        title.setGravity(Gravity.START);
        root.addView(title);

        TextView desc = new TextView(this);
        desc.setText("Local-only contacts, messages, and call-log sync for OpenCall Mac. Keep this app installed and grant permissions. Sensitive endpoints require the token below.");
        desc.setPadding(0, 12, 0, 20);
        root.addView(desc);

        status = new TextView(this);
        status.setTextSize(14);
        status.setTextIsSelectable(true);
        root.addView(status);

        Button perms = new Button(this);
        perms.setText("Grant permissions");
        perms.setOnClickListener(v -> requestNeededPermissions());
        root.addView(perms);

        Button copyUrl = new Button(this);
        copyUrl.setText("Copy URL + token");
        copyUrl.setOnClickListener(v -> copy(server.localUrl() + "\nToken: " + server.token()));
        root.addView(copyUrl);

        Button reset = new Button(this);
        reset.setText("Reset token");
        reset.setOnClickListener(v -> { server.resetToken(); refreshStatus(); });
        root.addView(reset);

        Button battery = new Button(this);
        battery.setText("Battery optimization settings");
        battery.setOnClickListener(v -> openBatterySettings());
        root.addView(battery);

        Button refresh = new Button(this);
        refresh.setText("Refresh status");
        refresh.setOnClickListener(v -> { OpenCallCompanionService.bluetoothMetaServer(this).start(); OpenCallCompanionService.bleMetaServer(this).start(); refreshStatus(); });
        root.addView(refresh);

        setContentView(scroll);
    }

    private void startService() {
        Intent i = new Intent(this, OpenCallCompanionService.class);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
    }

    private void requestNeededPermissions() {
        ArrayList<String> needed = new ArrayList<>();
        addIfMissing(needed, Manifest.permission.READ_CONTACTS);
        addIfMissing(needed, Manifest.permission.READ_SMS);
        addIfMissing(needed, Manifest.permission.SEND_SMS);
        addIfMissing(needed, Manifest.permission.CALL_PHONE);
        addIfMissing(needed, Manifest.permission.ANSWER_PHONE_CALLS);
        addIfMissing(needed, Manifest.permission.READ_CALL_LOG);
        addIfMissing(needed, Manifest.permission.READ_PHONE_STATE);
        if (Build.VERSION.SDK_INT >= 31) {
            addIfMissing(needed, Manifest.permission.BLUETOOTH_CONNECT);
            addIfMissing(needed, Manifest.permission.BLUETOOTH_ADVERTISE);
        }
        if (Build.VERSION.SDK_INT >= 33) addIfMissing(needed, Manifest.permission.POST_NOTIFICATIONS);
        if (!needed.isEmpty()) requestPermissions(needed.toArray(new String[0]), 7);
        else Toast.makeText(this, "All requested permissions already granted", Toast.LENGTH_SHORT).show();
    }

    private void addIfMissing(ArrayList<String> needed, String permission) {
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) needed.add(permission);
    }


    private void refreshStatus() {
        StringBuilder sb = new StringBuilder();
        sb.append("Server: ").append(server.isRunning() ? "running" : "starting").append("\n");
        sb.append("URL: ").append(server.localUrl()).append("\n");
        sb.append("Token: ").append(server.token()).append("\n\n");
        sb.append("Permissions:\n");
        appendPerm(sb, "Contacts", Manifest.permission.READ_CONTACTS);
        appendPerm(sb, "SMS read", Manifest.permission.READ_SMS);
        appendPerm(sb, "SMS send", Manifest.permission.SEND_SMS);
        appendPerm(sb, "Phone dial", Manifest.permission.CALL_PHONE);
        appendPerm(sb, "Phone answer/hangup", Manifest.permission.ANSWER_PHONE_CALLS);
        appendPerm(sb, "Call log", Manifest.permission.READ_CALL_LOG);
        appendPerm(sb, "Phone state", Manifest.permission.READ_PHONE_STATE);
        if (Build.VERSION.SDK_INT >= 31) {
            appendPerm(sb, "Bluetooth connect", Manifest.permission.BLUETOOTH_CONNECT);
            appendPerm(sb, "Bluetooth advertise", Manifest.permission.BLUETOOTH_ADVERTISE);
        }
        if (Build.VERSION.SDK_INT >= 33) appendPerm(sb, "Notifications", Manifest.permission.POST_NOTIFICATIONS);
        boolean classic = OpenCallCompanionService.bluetoothMetaServer(this).isRunning();
        boolean ble = OpenCallCompanionService.bleMetaServer(this).isRunning();
        sb.append("\nClassic Bluetooth discovery: ").append(classic ? "running" : "not running / permission needed").append("\n");
        sb.append("BLE discovery: ").append(ble ? "running" : "not running");
        String bleError = OpenCallCompanionService.bleMetaServer(this).lastError();
        if (bleError != null) sb.append(" (").append(bleError).append(")");
        sb.append("\nUUID: ").append(BluetoothMetaServer.SERVICE_UUID).append("\n");
        sb.append("BLE characteristic: ").append(BleMetaServer.CHARACTERISTIC_UUID).append("\n");
        sb.append("\nEndpoints:\n/health\n/call-state?token=TOKEN\n/contacts?token=TOKEN\n/calls?token=TOKEN\n/sms?token=TOKEN\nPOST /dial?token=TOKEN {\"number\":\"...\"}\nPOST /send-sms?token=TOKEN {\"number\":\"...\",\"text\":\"...\"}\n");
        status.setText(sb.toString());
    }

    private void appendPerm(StringBuilder sb, String label, String permission) {
        sb.append("- ").append(label).append(": ")
                .append(checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED ? "granted" : "missing")
                .append("\n");
    }

    private void openBatterySettings() {
        try {
            Intent request = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            request.setData(Uri.parse("package:" + getPackageName()));
            startActivity(request);
        } catch (Exception e) {
            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
        }
    }

    private void copy(String text) {
        ((ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("OpenCall Companion", text));
        Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show();
    }
}
