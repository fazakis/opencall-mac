# OpenCall Mac

Local Android phone-control utility for macOS. OpenCall uses the Android companion as the primary local backend for phone state, dialing, contacts, recent calls, and SMS. Native macOS Bluetooth HFP is kept as an optional/fallback helper for controls that still work on a given Mac/phone/macOS combination.

This does **not** use KDE Connect, ADB, root, or cloud. The default architecture is local-only:

- Android companion HTTP API on the phone (`:9096`) for `/call-state`, `/dial`, `/contacts`, `/calls`, and `/sms`.
- Mac menu-bar app for UI, notifications, sync display, and dispatching companion requests.
- Bundled Bluetooth helpers (`btmeta`, `hfpctl`) for trusted local discovery and native HFP fallback.

OpenCall does **not** route cellular call audio through the computer for now. Call audio stays on the phone/Bluetooth route selected by Android/macOS/AirPods.

## Build

```bash
./scripts/build.sh
```

The app is built at:

```text
~/opencall-mac/build/OpenCall Mac.app
```

## Run

```bash
./scripts/run.sh
```

## Logs

```text
~/opencall-mac/logs/hfp.log
```

The helper redacts phone-number-looking text in logs.

## Notes

The current known phone is Xiaomi MIX Fold 2 at Bluetooth address `bc-6a-d1-4d-f2-df`. The app still lists paired devices so another paired phone can be selected.

## Dialing

Enter a phone number in the app and press **Dial**. By default the Mac sends a token-protected local HTTP request to the Android companion:

```text
POST /dial?token=TOKEN {"number":"..."}
```

The phone places the cellular call locally using its normal telephony stack. If the companion is unavailable and a paired Bluetooth phone is selected, the app can fall back to the bundled native HFP helper. Phone-number-looking text is redacted in logs.

## Android Companion

The Android companion APK is built into:

```text
apk/OpenCallCompanion-debug.apk
```

Install it on the phone, open it, grant Contacts/SMS/Call Log/Phone permissions, then copy the displayed URL and token into OpenCall Mac.

The companion serves local JSON endpoints on the phone at port `9096`:

- `/health`
- `/call-state?token=TOKEN`
- `/contacts?token=TOKEN`
- `/calls?token=TOKEN`
- `/sms?token=TOKEN`
- `POST /dial?token=TOKEN`

Sensitive endpoints require the token shown in the Android app.

### Persistent service and Bluetooth auto-discovery

The Android companion runs its local HTTP sync API from a foreground service with a persistent notification. Closing the Android UI should leave the service running; the app also starts again after boot/package replacement and schedules a quick restart if the task is swiped away.

For setup convenience, the companion advertises Bluetooth metadata two ways: a BLE GATT service first, and a classic RFCOMM fallback. Both use the service UUID:

```text
9fb61f76-4a9d-4f97-a6be-2a97f6f7f2b1
```

OpenCall Mac includes the bundled `btmeta` helper and an **Auto via Bluetooth** button in the Android Companion panel. Select the paired phone, press the button, and the Mac app first scans BLE for the companion metadata characteristic, then falls back to classic RFCOMM SDP/channel discovery. The Android app returns its local URL, port, token, and status. Contacts/SMS/call-log/call-state/dial traffic still uses local HTTP on the phone's Wi-Fi/LAN/hotspot IP; Bluetooth is only used for trusted local discovery metadata and optional HFP fallback.

BLE metadata characteristic UUID:

```text
9fb61f77-4a9d-4f97-a6be-2a97f6f7f2b1
```


## OpenCall Mac resident mode

OpenCall Mac is now built as a menu-bar resident utility (`LSUIElement`) with a matching app/menu icon. The window is available from the menu-bar item.

Resident features:

- remembers the Android companion URL/token and last selected Bluetooth phone;
- optional Launch at Login toggle, implemented with `~/Library/LaunchAgents/local.opencall.mac.plist`;
- background call-state monitoring through the Android companion, with native HFP status polling only as fallback when the companion is not configured/reachable;
- background SMS polling through the Android companion and local macOS notifications for new inbox messages.

Message and incoming-call notifications require the Android companion HTTP server to be reachable and a saved companion URL/token. If the companion is unavailable, OpenCall can fall back to the selected paired Bluetooth phone and bundled `hfpctl` helper where native HFP works.

### Enable macOS notifications

OpenCall Mac asks for notification permission the first time it tries to show a notification. To enable or fix notifications:

1. Run OpenCall Mac:

   ```bash
   ./scripts/run.sh
   ```

2. Open the menu-bar window and click **Test notification**.
3. If macOS shows a permission prompt, choose **Allow**.
4. If notifications were denied or no prompt appears, open:

   ```text
   System Settings → Notifications → OpenCall Mac
   ```

   Then enable **Allow Notifications**. For best results, also enable **Banners**, **Sounds**, and **Show in Notification Center**.
5. Make sure Focus / Do Not Disturb is not suppressing banners.

You can also trigger the first permission request from Terminal:

```bash
open "build/OpenCall Mac.app" --args --test-notification
```

Because OpenCall Mac is an unsigned menu-bar utility (`LSUIElement`), macOS may occasionally suppress standard Notification Center banners. The app also shows its own floating notification panel as a fallback for incoming calls and SMS events.

## License

MIT License. See [LICENSE](LICENSE).
