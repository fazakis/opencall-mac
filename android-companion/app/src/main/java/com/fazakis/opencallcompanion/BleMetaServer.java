package com.fazakis.opencallcompanion;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.ParcelUuid;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.UUID;

final class BleMetaServer {
    static final UUID SERVICE_UUID = UUID.fromString("9fb61f76-4a9d-4f97-a6be-2a97f6f7f2b1");
    static final UUID CHARACTERISTIC_UUID = UUID.fromString("9fb61f77-4a9d-4f97-a6be-2a97f6f7f2b1");

    private final Context context;
    private final LocalHttpServer httpServer;
    private BluetoothGattServer gattServer;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothGattCharacteristic characteristic;
    private volatile boolean running = false;
    private volatile String lastError = null;

    BleMetaServer(Context context, LocalHttpServer httpServer) {
        this.context = context.getApplicationContext();
        this.httpServer = httpServer;
    }

    synchronized void start() {
        if (running) return;
        if (!canUseBle()) { lastError = "missing_bluetooth_permission"; return; }
        BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        if (manager == null) { lastError = "no_bluetooth_manager"; return; }
        BluetoothAdapter adapter = manager.getAdapter();
        if (adapter == null || !adapter.isEnabled()) { lastError = "bluetooth_off"; return; }
        advertiser = adapter.getBluetoothLeAdvertiser();
        if (advertiser == null) { lastError = "ble_advertiser_unavailable"; return; }
        try {
            gattServer = manager.openGattServer(context, callback);
            if (gattServer == null) { lastError = "gatt_server_unavailable"; return; }
            BluetoothGattService service = new BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY);
            characteristic = new BluetoothGattCharacteristic(
                    CHARACTERISTIC_UUID,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ);
            service.addCharacteristic(characteristic);
            gattServer.addService(service);

            AdvertiseSettings settings = new AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setConnectable(true)
                    .setTimeout(0)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                    .build();
            AdvertiseData data = new AdvertiseData.Builder()
                    .addServiceUuid(new ParcelUuid(SERVICE_UUID))
                    .setIncludeDeviceName(false)
                    .build();
            advertiser.startAdvertising(settings, data, advertiseCallback);
            running = true;
            lastError = null;
        } catch (SecurityException se) {
            stop();
            lastError = "security_exception";
        } catch (Exception e) {
            stop();
            lastError = e.getClass().getSimpleName();
        }
    }

    synchronized void stop() {
        try { if (advertiser != null) advertiser.stopAdvertising(advertiseCallback); } catch (Exception ignored) {}
        try { if (gattServer != null) gattServer.close(); } catch (Exception ignored) {}
        advertiser = null;
        gattServer = null;
        characteristic = null;
        running = false;
    }

    boolean isRunning() { return running; }
    String lastError() { return lastError; }

    boolean canUseBle() {
        if (Build.VERSION.SDK_INT >= 31) {
            return context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                    && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    private byte[] metadataBytes() {
        try {
            JSONObject obj = new JSONObject();
            obj.put("ok", true);
            obj.put("service", "OpenCall Companion");
            obj.put("version", 3);
            obj.put("transport", "ble-gatt");
            obj.put("url", httpServer.localUrl());
            obj.put("port", LocalHttpServer.PORT);
            obj.put("token", httpServer.token());
            obj.put("bluetoothUuid", SERVICE_UUID.toString());
            obj.put("characteristicUuid", CHARACTERISTIC_UUID.toString());
            return (obj.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            return ("{\"ok\":false,\"error\":\"" + e.getClass().getSimpleName() + "\"}\n").getBytes(StandardCharsets.UTF_8);
        }
    }

    private final BluetoothGattServerCallback callback = new BluetoothGattServerCallback() {
        @Override public void onCharacteristicReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattCharacteristic ch) {
            if (!CHARACTERISTIC_UUID.equals(ch.getUuid())) {
                try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null); } catch (Exception ignored) {}
                return;
            }
            byte[] bytes = metadataBytes();
            if (offset < 0 || offset > bytes.length) {
                try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null); } catch (Exception ignored) {}
                return;
            }
            byte[] slice = Arrays.copyOfRange(bytes, offset, bytes.length);
            try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice); } catch (Exception ignored) {}
        }
    };

    private final AdvertiseCallback advertiseCallback = new AdvertiseCallback() {
        @Override public void onStartSuccess(AdvertiseSettings settingsInEffect) {
            running = true;
            lastError = null;
        }
        @Override public void onStartFailure(int errorCode) {
            running = false;
            lastError = "advertise_failed_" + errorCode;
        }
    };
}
