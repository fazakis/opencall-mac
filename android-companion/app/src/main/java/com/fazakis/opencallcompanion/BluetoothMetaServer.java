package com.fazakis.opencallcompanion;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothServerSocket;
import android.bluetooth.BluetoothSocket;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

import org.json.JSONObject;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

final class BluetoothMetaServer {
    static final UUID SERVICE_UUID = UUID.fromString("9fb61f76-4a9d-4f97-a6be-2a97f6f7f2b1");
    private static final String SERVICE_NAME = "OpenCall Companion Metadata";

    private final Context context;
    private final LocalHttpServer httpServer;
    private BluetoothServerSocket serverSocket;
    private Thread thread;
    private volatile boolean running = false;

    BluetoothMetaServer(Context context, LocalHttpServer httpServer) {
        this.context = context.getApplicationContext();
        this.httpServer = httpServer;
    }

    synchronized void start() {
        if (running) return;
        if (!canUseBluetooth()) return;
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) return;
        running = true;
        thread = new Thread(this::loop, "OpenCallBluetoothMetaServer");
        thread.start();
    }

    synchronized void stop() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (Exception ignored) {}
        serverSocket = null;
    }

    boolean isRunning() { return running; }

    boolean canUseBluetooth() {
        if (Build.VERSION.SDK_INT >= 31) {
            return context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    private void loop() {
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null) { running = false; return; }
        try (BluetoothServerSocket ss = adapter.listenUsingInsecureRfcommWithServiceRecord(SERVICE_NAME, SERVICE_UUID)) {
            serverSocket = ss;
            while (running) {
                BluetoothSocket socket = ss.accept();
                handle(socket);
            }
        } catch (SecurityException se) {
            running = false;
        } catch (Exception e) {
            running = false;
        }
    }

    private void handle(BluetoothSocket socket) {
        try (BluetoothSocket s = socket; OutputStream out = s.getOutputStream()) {
            JSONObject obj = new JSONObject();
            obj.put("ok", true);
            obj.put("service", "OpenCall Companion");
            obj.put("version", 5);
            obj.put("transport", "classic-rfcomm-insecure");
            obj.put("url", httpServer.localUrl());
            obj.put("port", LocalHttpServer.PORT);
            obj.put("token", httpServer.token());
            obj.put("bluetoothUuid", SERVICE_UUID.toString());
            out.write((obj.toString() + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
            OpenCallCompanionService.noteMacSeen(context);
        } catch (Exception ignored) {
        }
    }
}
