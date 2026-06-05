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
    static final UUID ENDPOINT_CHARACTERISTIC_UUID = UUID.fromString("9fb61f78-4a9d-4f97-a6be-2a97f6f7f2b1");
    static final UUID TOKEN_CHARACTERISTIC_UUID = UUID.fromString("9fb61f79-4a9d-4f97-a6be-2a97f6f7f2b1");
    private static final int MANUFACTURER_ID = 0xF105;

    private static final long STARTUP_BOOST_MS = 5 * 60 * 1000L;
    private static final long RECENT_MAC_WINDOW_MS = 30 * 1000L;
    private static final long REDISCOVERY_AFTER_MS = 2 * 60 * 1000L;
    private static final long REDISCOVERY_BOOST_MS = 2 * 60 * 1000L;
    private static final long MODE_CHECK_MS = 30 * 1000L;

    private final Context context;
    private final LocalHttpServer httpServer;
    private BluetoothGattServer gattServer;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothGattCharacteristic characteristic;
    private BluetoothGattCharacteristic endpointCharacteristic;
    private BluetoothGattCharacteristic tokenCharacteristic;
    private Thread modeThread;
    private volatile boolean running = false;
    private volatile boolean advertising = false;
    private volatile int advertiseMode = -1;
    private volatile int txPowerLevel = -1;
    private volatile long lastMacSeenAt = 0;
    private volatile long boostUntil = 0;
    private volatile long lastBoostStartedAt = 0;
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
            endpointCharacteristic = new BluetoothGattCharacteristic(
                    ENDPOINT_CHARACTERISTIC_UUID,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ);
            tokenCharacteristic = new BluetoothGattCharacteristic(
                    TOKEN_CHARACTERISTIC_UUID,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ);
            service.addCharacteristic(characteristic);
            service.addCharacteristic(endpointCharacteristic);
            service.addCharacteristic(tokenCharacteristic);
            gattServer.addService(service);

            running = true;
            long now = System.currentTimeMillis();
            boostUntil = now + STARTUP_BOOST_MS;
            lastBoostStartedAt = now;
            refreshAdvertisingModeLocked(now);
            startModeThreadLocked();
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
        running = false;
        try { if (advertiser != null && advertising) advertiser.stopAdvertising(advertiseCallback); } catch (Exception ignored) {}
        try { if (gattServer != null) gattServer.close(); } catch (Exception ignored) {}
        advertiser = null;
        gattServer = null;
        characteristic = null;
        advertising = false;
        advertiseMode = -1;
        txPowerLevel = -1;
    }

    synchronized void noteMacSeen() {
        lastMacSeenAt = System.currentTimeMillis();
        boostUntil = 0;
        refreshAdvertisingModeLocked(lastMacSeenAt);
    }

    boolean isRunning() { return running && advertising; }
    String lastError() { return lastError; }
    long lastMacSeenAt() { return lastMacSeenAt; }
    String advertiseModeName() {
        switch (advertiseMode) {
            case AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY: return "low-latency";
            case AdvertiseSettings.ADVERTISE_MODE_BALANCED: return "balanced";
            case AdvertiseSettings.ADVERTISE_MODE_LOW_POWER: return "low-power";
            default: return advertising ? "unknown" : "stopped";
        }
    }

    boolean canUseBle() {
        if (Build.VERSION.SDK_INT >= 31) {
            return context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                    && context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    private void startModeThreadLocked() {
        if (modeThread != null && modeThread.isAlive()) return;
        modeThread = new Thread(this::modeLoop, "OpenCallBleModeManager");
        modeThread.start();
    }

    private void modeLoop() {
        while (running) {
            try { Thread.sleep(MODE_CHECK_MS); } catch (InterruptedException ignored) {}
            synchronized (this) {
                if (running) refreshAdvertisingModeLocked(System.currentTimeMillis());
            }
        }
    }

    private void refreshAdvertisingModeLocked(long now) {
        if (!running || advertiser == null) return;
        boolean recentlySeen = lastMacSeenAt > 0 && now - lastMacSeenAt <= RECENT_MAC_WINDOW_MS;
        if (!recentlySeen && boostUntil <= now) {
            long reference = lastMacSeenAt > 0 ? lastMacSeenAt : lastBoostStartedAt;
            if (reference > 0 && now - reference >= REDISCOVERY_AFTER_MS) {
                boostUntil = now + REDISCOVERY_BOOST_MS;
                lastBoostStartedAt = now;
            }
        }
        boolean boosted = !recentlySeen && boostUntil > now;
        int desiredMode = boosted ? AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY : AdvertiseSettings.ADVERTISE_MODE_LOW_POWER;
        int desiredPower = boosted ? AdvertiseSettings.ADVERTISE_TX_POWER_HIGH : AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM;
        startAdvertisingLocked(desiredMode, desiredPower);
    }

    private void startAdvertisingLocked(int mode, int power) {
        if (advertising && advertiseMode == mode && txPowerLevel == power) return;
        try { if (advertiser != null && advertising) advertiser.stopAdvertising(advertiseCallback); } catch (Exception ignored) {}
        AdvertiseSettings settings = new AdvertiseSettings.Builder()
                .setAdvertiseMode(mode)
                .setConnectable(true)
                .setTimeout(0)
                .setTxPowerLevel(power)
                .build();
        AdvertiseData data = new AdvertiseData.Builder()
                .addManufacturerData(MANUFACTURER_ID, advertisementPayload())
                .setIncludeDeviceName(false)
                .build();
        try {
            advertiser.startAdvertising(settings, data, advertiseCallback);
            advertising = true;
            advertiseMode = mode;
            txPowerLevel = power;
            lastError = null;
        } catch (SecurityException se) {
            advertising = false;
            advertiseMode = -1;
            txPowerLevel = -1;
            lastError = "security_exception";
        } catch (Exception e) {
            advertising = false;
            advertiseMode = -1;
            txPowerLevel = -1;
            lastError = e.getClass().getSimpleName();
        }
    }

    private byte[] metadataBytes() {
        try {
            JSONObject obj = new JSONObject();
            obj.put("ok", true);
            obj.put("service", "OpenCall Companion");
            obj.put("version", 10);
            obj.put("transport", "ble-gatt");
            obj.put("url", httpServer.localUrl());
            obj.put("port", LocalHttpServer.PORT);
            obj.put("token", httpServer.token());
            obj.put("bluetoothUuid", SERVICE_UUID.toString());
            obj.put("characteristicUuid", CHARACTERISTIC_UUID.toString());
            obj.put("endpointCharacteristicUuid", ENDPOINT_CHARACTERISTIC_UUID.toString());
            obj.put("tokenCharacteristicUuid", TOKEN_CHARACTERISTIC_UUID.toString());
            obj.put("advertiseMode", advertiseModeName());
            return (obj.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            return ("{\"ok\":false,\"error\":\"" + e.getClass().getSimpleName() + "\"}\n").getBytes(StandardCharsets.UTF_8);
        }
    }


    private byte[] endpointBytes() {
        String endpoint = httpServer.localUrl()
                .replace("http://", "")
                .replace("https://", "");
        return endpoint.getBytes(StandardCharsets.UTF_8);
    }

    private byte[] tokenBytes() {
        return httpServer.token().getBytes(StandardCharsets.UTF_8);
    }


    private byte[] advertisementPayload() {
        byte[] token = httpServer.token().getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[1 + 4 + token.length];
        out[0] = 10;
        String endpoint = httpServer.localUrl()
                .replace("http://", "")
                .replace("https://", "");
        String host = endpoint;
        int colon = endpoint.indexOf(':');
        if (colon >= 0) host = endpoint.substring(0, colon);
        String[] parts = host.split("\\.");
        for (int i = 0; i < 4; i++) {
            int value = 0;
            try { if (i < parts.length) value = Integer.parseInt(parts[i]); } catch (Exception ignored) {}
            out[1 + i] = (byte) (value & 0xff);
        }
        System.arraycopy(token, 0, out, 5, token.length);
        return out;
    }

    private final BluetoothGattServerCallback callback = new BluetoothGattServerCallback() {
        @Override public void onCharacteristicReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattCharacteristic ch) {
            UUID uuid = ch.getUuid();
            byte[] bytes;
            if (CHARACTERISTIC_UUID.equals(uuid)) {
                bytes = metadataBytes();
            } else if (ENDPOINT_CHARACTERISTIC_UUID.equals(uuid)) {
                bytes = endpointBytes();
            } else if (TOKEN_CHARACTERISTIC_UUID.equals(uuid)) {
                bytes = tokenBytes();
            } else {
                try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null); } catch (Exception ignored) {}
                return;
            }
            if (offset < 0 || offset > bytes.length) {
                try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null); } catch (Exception ignored) {}
                return;
            }
            byte[] slice = Arrays.copyOfRange(bytes, offset, bytes.length);
            try { gattServer.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice); } catch (Exception ignored) {}
            noteMacSeen();
        }
    };

    private final AdvertiseCallback advertiseCallback = new AdvertiseCallback() {
        @Override public void onStartSuccess(AdvertiseSettings settingsInEffect) {
            advertising = true;
            lastError = null;
        }
        @Override public void onStartFailure(int errorCode) {
            advertising = false;
            advertiseMode = -1;
            txPowerLevel = -1;
            lastError = "advertise_failed_" + errorCode;
        }
    };
}
