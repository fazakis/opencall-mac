import SwiftUI
import AppKit
import IOBluetooth
import CoreBluetooth
import Foundation
import UserNotifications

struct PhoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    var displayName: String { name.isEmpty ? address : "\(name) — \(address)" }
}

struct CommandResult {
    let text: String
    let exitCode: Int32
}

struct ProcessOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct SyncError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}


private let companionBluetoothServiceUUIDString = "9fb61f76-4a9d-4f97-a6be-2a97f6f7f2b1"
private let companionBluetoothCharacteristicUUIDString = "9fb61f77-4a9d-4f97-a6be-2a97f6f7f2b1"
private let companionBluetoothEndpointCharacteristicUUIDString = "9fb61f78-4a9d-4f97-a6be-2a97f6f7f2b1"
private let companionBluetoothTokenCharacteristicUUIDString = "9fb61f79-4a9d-4f97-a6be-2a97f6f7f2b1"
private let companionBluetoothManufacturerID: UInt16 = 0xF105

final class CompanionBLEDiscoverer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: companionBluetoothServiceUUIDString)
    private let characteristicUUID = CBUUID(string: companionBluetoothCharacteristicUUIDString)
    private let endpointCharacteristicUUID = CBUUID(string: companionBluetoothEndpointCharacteristicUUIDString)
    private let tokenCharacteristicUUID = CBUUID(string: companionBluetoothTokenCharacteristicUUIDString)
    private let queue = DispatchQueue(label: "local.opencall.mac.ble-discovery")
    private let timeout: TimeInterval
    private let completion: (Result<String, Error>) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var finished = false
    private var discoveredAdvertisements = 0
    private var probedAdvertisements = 0
    private var probingUnadvertisedPeripheral = false
    private var triedPeripheralIDs = Set<UUID>()
    private var usingTargetedScan = false
    private var advertisementSummaries: [String] = []
    private var metadataCharacteristic: CBCharacteristic?
    private var endpointCharacteristic: CBCharacteristic?
    private var tokenCharacteristic: CBCharacteristic?
    private var endpointText: String?
    private var tokenText: String?

    init(timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        self.timeout = timeout
        self.completion = completion
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.finish(.failure(SyncError("Timed out waiting for BLE OpenCall Companion metadata; saw \(self.discoveredAdvertisements) BLE advertisement(s), probed \(self.probedAdvertisements) peripheral(s)\(self.advertisementSummaries.isEmpty ? "" : "; advertisements: " + self.advertisementSummaries.joined(separator: " | "))")))
        }
    }

    private func finish(_ value: Result<String, Error>) {
        if finished { return }
        finished = true
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        DispatchQueue.main.async { self.completion(value) }
    }

    private func metadataFromAdvertisement(_ advertisementData: [String: Any]) -> String? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return nil }
        let bytes = [UInt8](data)
        let payloadStart: Int
        if bytes.count >= 2,
           UInt16(bytes[0]) | (UInt16(bytes[1]) << 8) == companionBluetoothManufacturerID {
            payloadStart = 2
        } else if bytes.first == 9 {
            // Some CoreBluetooth surfaces strip the company id; accept the raw payload too.
            payloadStart = 0
        } else {
            return nil
        }
        guard bytes.count >= payloadStart + 1 + 4 + 1 else { return nil }
        let version = bytes[payloadStart]
        guard version >= 9 else { return nil }
        let ipBytes = bytes[(payloadStart + 1)..<(payloadStart + 5)]
        let port: UInt16
        let tokenStart: Int
        if version >= 10 {
            port = 9096
            tokenStart = payloadStart + 5
        } else {
            guard bytes.count >= payloadStart + 1 + 4 + 2 + 1 else { return nil }
            let portHigh = UInt16(bytes[payloadStart + 5])
            let portLow = UInt16(bytes[payloadStart + 6])
            port = (portHigh << 8) | portLow
            tokenStart = payloadStart + 7
        }
        let tokenBytes = bytes[tokenStart..<bytes.count]
        guard let token = String(bytes: tokenBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let host = ipBytes.map(String.init).joined(separator: ".")
        let url = "http://\(host):\(port)"
        return """
        {"ok":true,"service":"OpenCall Companion","version":\(version),"transport":"ble-advertisement","url":"\(url)","token":"\(token)","bluetoothUuid":"\(companionBluetoothServiceUUIDString)"}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func useDiscoveredPeripheral(_ peripheral: CBPeripheral, central: CBCentralManager, advertisedMatch: Bool) {
        self.peripheral = peripheral
        probingUnadvertisedPeripheral = !advertisedMatch
        if !advertisedMatch { probedAdvertisements += 1 }
        peripheral.delegate = self
        central.stopScan()
        if peripheral.state == .connected {
            peripheral.discoverServices([serviceUUID])
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func resumeScanningAfterProbeMiss() {
        guard !finished, let central else { return }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        probingUnadvertisedPeripheral = false
        usingTargetedScan = false
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
                useDiscoveredPeripheral(connected, central: central, advertisedMatch: true)
                return
            }
            usingTargetedScan = true
            central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            queue.asyncAfter(deadline: .now() + 8.0) { [weak self, weak central] in
                guard let self, let central else { return }
                if !self.finished && self.peripheral == nil && self.usingTargetedScan {
                    self.usingTargetedScan = false
                    central.stopScan()
                    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                }
            }
        case .unsupported:
            finish(.failure(SyncError("BLE is unsupported on this Mac")))
        case .unauthorized:
            finish(.failure(SyncError("Bluetooth permission denied for BLE discovery")))
        case .poweredOff:
            finish(.failure(SyncError("Bluetooth is powered off")))
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredAdvertisements += 1
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowUUIDs = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let solicitedUUIDs = (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        if let json = metadataFromAdvertisement(advertisementData) {
            finish(.success(json))
            return
        }
        if advertisementSummaries.count < 8 {
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = localName ?? peripheral.name ?? "(unnamed)"
            let svc = (serviceUUIDs + overflowUUIDs + solicitedUUIDs + Array(serviceData.keys)).prefix(4).map { $0.uuidString }.joined(separator: ",")
            advertisementSummaries.append("name=\(name), rssi=\(RSSI), services=\(svc.isEmpty ? "none" : svc)")
        }
        let advertisedMatch = usingTargetedScan
                || serviceUUIDs.contains(serviceUUID)
                || overflowUUIDs.contains(serviceUUID)
                || solicitedUUIDs.contains(serviceUUID)
                || serviceData.keys.contains(serviceUUID)
        if advertisedMatch {
            useDiscoveredPeripheral(peripheral, central: central, advertisedMatch: true)
            return
        }
        // Some Android/Tahoe combinations keep the GATT service off the advertisement
        // payload. Probe a bounded number of discovered peripherals and discover the
        // OpenCall service over GATT before giving up.
        guard self.peripheral == nil,
              probedAdvertisements < 12,
              !triedPeripheralIDs.contains(peripheral.identifier) else { return }
        triedPeripheralIDs.insert(peripheral.identifier)
        useDiscoveredPeripheral(peripheral, central: central, advertisedMatch: false)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if probingUnadvertisedPeripheral {
            resumeScanningAfterProbeMiss()
            return
        }
        finish(.failure(SyncError("BLE connect failed: \(error?.localizedDescription ?? "unknown")")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if probingUnadvertisedPeripheral {
            resumeScanningAfterProbeMiss()
            return
        }
        if !finished, let error {
            finish(.failure(SyncError("BLE disconnected before metadata read: \(error.localizedDescription)")))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { finish(.failure(SyncError("BLE service discovery failed: \(error.localizedDescription)"))); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            if probingUnadvertisedPeripheral {
                resumeScanningAfterProbeMiss()
                return
            }
            finish(.failure(SyncError("BLE OpenCall Companion service not found")))
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID, endpointCharacteristicUUID, tokenCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { finish(.failure(SyncError("BLE characteristic discovery failed: \(error.localizedDescription)"))); return }
        metadataCharacteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID })
        endpointCharacteristic = service.characteristics?.first(where: { $0.uuid == endpointCharacteristicUUID })
        tokenCharacteristic = service.characteristics?.first(where: { $0.uuid == tokenCharacteristicUUID })
        readNextBluetoothMetadataValue(peripheral)
    }

    private func readNextBluetoothMetadataValue(_ peripheral: CBPeripheral) {
        if endpointText == nil, let endpointCharacteristic {
            peripheral.readValue(for: endpointCharacteristic)
            return
        }
        if tokenText == nil, let tokenCharacteristic {
            peripheral.readValue(for: tokenCharacteristic)
            return
        }
        if let endpointText, let tokenText, !endpointText.isEmpty, !tokenText.isEmpty {
            let url = endpointText.hasPrefix("http://") || endpointText.hasPrefix("https://") ? endpointText : "http://\(endpointText)"
            let json = """
            {"ok":true,"service":"OpenCall Companion","version":8,"transport":"ble-gatt-short","url":"\(url)","token":"\(tokenText)","bluetoothUuid":"\(companionBluetoothServiceUUIDString)"}
            """.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.success(json))
            return
        }
        if let metadataCharacteristic {
            peripheral.readValue(for: metadataCharacteristic)
            return
        }
        finish(.failure(SyncError("BLE OpenCall metadata characteristics not found")))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(SyncError("BLE metadata read failed: \(error.localizedDescription)"))); return }
        guard let data = characteristic.value, !data.isEmpty else {
            finish(.failure(SyncError("BLE metadata characteristic was empty")))
            return
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            finish(.failure(SyncError("BLE metadata was not UTF-8 text")))
            return
        }
        if characteristic.uuid == endpointCharacteristicUUID {
            endpointText = text
            readNextBluetoothMetadataValue(peripheral)
            return
        }
        if characteristic.uuid == tokenCharacteristicUUID {
            tokenText = text
            readNextBluetoothMetadataValue(peripheral)
            return
        }
        finish(.success(text))
    }
}

private final class CompanionSDPWaiter: NSObject {
    private let runLoop: CFRunLoop
    var done = false
    var status: IOReturn = -1

    init(runLoop: CFRunLoop = CFRunLoopGetCurrent()) {
        self.runLoop = runLoop
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        self.status = status
        self.done = true
        CFRunLoopStop(runLoop)
    }

    func wait(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.2), deadline))
        }
    }
}

private final class CompanionRFCOMMReader: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var data = Data()
    var closed = false

    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel, data dataPointer: UnsafeMutableRawPointer, length dataLength: Int) {
        data.append(dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength)
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        closed = true
    }
}

private func companionUUIDBytes(_ uuid: String) throws -> [UInt8] {
    let hex = uuid.replacingOccurrences(of: "-", with: "")
    guard hex.count == 32 else { throw SyncError("Bad UUID: \(uuid)") }
    var bytes: [UInt8] = []
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { throw SyncError("Bad UUID byte in \(uuid)") }
        bytes.append(byte)
        idx = next
    }
    return bytes
}

private func companionSDPUUID(_ uuid: String) throws -> IOBluetoothSDPUUID {
    IOBluetoothSDPUUID(data: Data(try companionUUIDBytes(uuid)))
}

private func companionUUID16Value(_ uuid: IOBluetoothSDPUUID) -> UInt16? {
    guard let compact = uuid.getWithLength(2) else { return nil }
    let data = Data(referencing: compact)
    guard data.count == 2 else { return nil }
    return (UInt16(data[0]) << 8) | UInt16(data[1])
}

private func companionParseRFCOMMChannelID(from element: IOBluetoothSDPDataElement) -> BluetoothRFCOMMChannelID? {
    guard let children = element.getArrayValue() as? [IOBluetoothSDPDataElement] else { return nil }
    if children.count >= 2,
       let uuid = children[0].getUUIDValue(),
       companionUUID16Value(uuid) == 0x0003,
       let number = children[1].getNumberValue() {
        let channel = number.uint8Value
        if channel > 0 { return BluetoothRFCOMMChannelID(channel) }
    }
    for child in children {
        if let channel = companionParseRFCOMMChannelID(from: child) { return channel }
    }
    return nil
}

private func companionManuallyParsedRFCOMMChannelID(from service: IOBluetoothSDPServiceRecord) -> BluetoothRFCOMMChannelID? {
    guard let protocolList = service.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) else { return nil }
    return companionParseRFCOMMChannelID(from: protocolList)
}

private func companionIsOpenCallMetadata(_ text: String) -> Bool {
    text.contains("OpenCall Companion") && text.contains("token") && text.contains("url")
}

private func companionDevice(address rawAddress: String) throws -> IOBluetoothDevice {
    let wanted = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !wanted.isEmpty else { throw SyncError("Missing Bluetooth address") }
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    if let match = paired.first(where: { ($0.addressString ?? "").lowercased() == wanted }) { return match }
    if let device = IOBluetoothDevice(addressString: wanted) { return device }
    throw SyncError("Bluetooth device not found: \(rawAddress)")
}

private func companionReadRFCOMMMetadata(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, timeout: TimeInterval, requireOpenCall: Bool) throws -> String {
    let reader = CompanionRFCOMMReader()
    var channel: IOBluetoothRFCOMMChannel?
    let openStatus = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: reader)
    guard openStatus == kIOReturnSuccess, let channel else {
        throw SyncError(String(format: "RFCOMM open failed on channel %u: 0x%08x", channelID, openStatus))
    }
    defer { _ = channel.close() }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !reader.closed && !reader.data.contains(0x0a) {
        RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.05), deadline))
    }
    guard !reader.data.isEmpty else { throw SyncError("No metadata received on RFCOMM channel \(channelID)") }
    let text = String(data: reader.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw SyncError("Metadata was empty on RFCOMM channel \(channelID)") }
    if requireOpenCall && !companionIsOpenCallMetadata(text) {
        throw SyncError("RFCOMM channel \(channelID) did not return OpenCall metadata")
    }
    return text
}

private func companionScanRFCOMMChannels(device: IOBluetoothDevice, until deadline: Date) throws -> String {
    var failures: [String] = []
    for raw in 1...30 {
        if Date() >= deadline { break }
        let channelID = BluetoothRFCOMMChannelID(raw)
        let remaining = max(0.15, deadline.timeIntervalSinceNow)
        let perChannel = min(0.75, remaining)
        do {
            return try companionReadRFCOMMMetadata(device: device, channelID: channelID, timeout: perChannel, requireOpenCall: true)
        } catch {
            if failures.count < 5 { failures.append("ch\(raw): \(error.localizedDescription)") }
        }
    }
    throw SyncError("OpenCall RFCOMM channel scan failed (\(failures.joined(separator: "; ")))")
}

private func companionClassicMetadata(address: String, timeout: TimeInterval) throws -> String {
    let device = try companionDevice(address: address)
    let sdpUUID = try companionSDPUUID(companionBluetoothServiceUUIDString)
    let deadline = Date().addingTimeInterval(timeout)
    var errors: [String] = []
    var channelID: BluetoothRFCOMMChannelID?

    let waiter = CompanionSDPWaiter()
    let started = device.performSDPQuery(waiter)
    if started == kIOReturnSuccess {
        waiter.wait(timeout: min(8, max(3, timeout * 0.35)))
        if waiter.done, waiter.status == kIOReturnSuccess {
            if let service = device.getServiceRecord(for: sdpUUID) {
                var sdpChannel = BluetoothRFCOMMChannelID(0)
                let channelStatus = service.getRFCOMMChannelID(&sdpChannel)
                if channelStatus == kIOReturnSuccess, sdpChannel > 0 {
                    channelID = sdpChannel
                } else if let parsed = companionManuallyParsedRFCOMMChannelID(from: service), parsed > 0 {
                    channelID = parsed
                } else {
                    errors.append(String(format: "SDP service had no RFCOMM channel: 0x%08x", channelStatus))
                }
            } else {
                errors.append("OpenCall Companion service not found in SDP results")
            }
        } else if waiter.done {
            errors.append(String(format: "Bluetooth SDP query failed: 0x%08x", waiter.status))
        } else {
            errors.append("Timed out waiting for Bluetooth SDP query")
        }
    } else {
        errors.append(String(format: "SDP query failed to start: 0x%08x", started))
    }

    if let channelID {
        do {
            return try companionReadRFCOMMMetadata(device: device, channelID: channelID, timeout: max(1, deadline.timeIntervalSinceNow), requireOpenCall: false)
        } catch {
            errors.append("RFCOMM channel \(channelID) from SDP failed: \(error.localizedDescription)")
        }
    }

    do {
        return try companionScanRFCOMMChannels(device: device, until: deadline)
    } catch {
        errors.append("RFCOMM scan failed: \(error.localizedDescription)")
        throw SyncError(errors.joined(separator: "; "))
    }
}


struct HealthResponse: Decodable {    let ok: Bool
    let service: String?
    let running: Bool?
    let port: Int?
    let bluetoothRunning: Bool?
    let bluetoothUuid: String?
    let missingPermissions: [String]?
    let error: String?
}

struct CallStateResponse: Decodable {
    let ok: Bool
    let state: String?
    let stateCode: Int?
    let idle: Bool?
    let ringing: Bool?
    let offhook: Bool?
    let incomingNumber: String?
    let updatedAt: Int64?
    let listening: Bool?
    let error: String?
}

struct CompanionMetadata: Decodable {
    let ok: Bool?
    let service: String?
    let version: Int?
    let url: String?
    let port: Int?
    let token: String?
    let bluetoothUuid: String?
}

struct ContactsResponse: Decodable {
    let ok: Bool
    let contacts: [PhoneContact]?
    let count: Int?
    let error: String?
}

struct CallsResponse: Decodable {
    let ok: Bool
    let calls: [RecentCall]?
    let count: Int?
    let error: String?
}

struct SmsResponse: Decodable {
    let ok: Bool
    let messages: [SmsMessage]?
    let count: Int?
    let error: String?
}

struct SendSmsResponse: Decodable {
    let ok: Bool
    let sent: Bool?
    let number: String?
    let parts: Int?
    let error: String?
}

struct DialResponse: Decodable {
    let ok: Bool
    let dialed: Bool?
    let numberLength: Int?
    let error: String?
}

struct CallControlResponse: Decodable {
    let ok: Bool
    let answerRequested: Bool?
    let hangupRequested: Bool?
    let ended: Bool?
    let error: String?
}

struct PhoneContact: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let numbers: [ContactNumber]
}

struct ContactNumber: Codable, Identifiable, Hashable {
    let label: String
    let number: String
    var id: String { "\(label)-\(number)" }
}

struct RecentCall: Codable, Identifiable, Hashable {
    let id: String
    let number: String
    let name: String?
    let type: String
    let date: Int64
    let duration: Int64
}

struct SmsMessage: Codable, Identifiable, Hashable {
    let id: String
    let address: String
    let body: String
    let date: Int64
    let type: String
    let read: Bool
}

enum OpenCallNotificationKind: String {
    case generic
    case incomingCall
    case activeCall
    case sms
    case smsSummary
}

enum OpenCallNotificationCategory {
    static let incomingCall = "OPENCALL_INCOMING_CALL"
    static let sms = "OPENCALL_SMS"
}

enum OpenCallNotificationAction {
    static let answer = "OPENCALL_ANSWER"
    static let decline = "OPENCALL_DECLINE"
}


enum LaunchAgentManager {
    static let label = "local.opencall.mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        let dir = plistURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if enabled {
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(label)</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>-g</string>
                <string>\(appPath)</string>
              </array>
              <key>RunAtLoad</key><true/>
              <key>LimitLoadToSessionType</key><string>Aqua</string>
            </dict>
            </plist>
            """
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
        }
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    static var shared: AppModel?
    private static let contactsCacheKey = "cachedContacts"
    private static let recentCallsCacheKey = "cachedRecentCalls"
    private static let messagesCacheKey = "cachedSmsMessages"
    private static let activeCallPollPausedUntilKey = "activeCallPollPausedUntil"
    private static let activeCallPollPauseSeconds: TimeInterval = 90 * 60
    private static let companionFailuresBeforeHfpFallback = 3
    private static let hfpFallbackPollCooldown: TimeInterval = 60

    @Published var devices: [PhoneDevice] = []
    @Published var selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress") ?? "" {
        didSet {
            if !selectedAddress.isEmpty {
                UserDefaults.standard.set(selectedAddress, forKey: "selectedAddress")
            }
        }
    }
    @Published var output = "Ready. OpenCall uses the Android companion for phone state/dialing, with native macOS HFP as fallback."
    @Published var busy = false
    @Published var logText = ""
    @Published var dialNumber = UserDefaults.standard.string(forKey: "dialNumber") ?? "" {
        didSet {
            let trimmed = dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: "dialNumber")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "dialNumber")
            }
        }
    }

    @Published var companionURL = UserDefaults.standard.string(forKey: "companionURL") ?? "http://PHONE-IP:9096"
    @Published var companionToken = UserDefaults.standard.string(forKey: "companionToken") ?? ""
    @Published var syncStatus = "Install/open the Android companion, grant permissions, then paste its URL and token here."
    @Published var contacts: [PhoneContact] = AppModel.loadCachedArray(AppModel.contactsCacheKey, as: [PhoneContact].self)
    @Published var recentCalls: [RecentCall] = AppModel.loadCachedArray(AppModel.recentCallsCacheKey, as: [RecentCall].self)
    @Published var messages: [SmsMessage] = AppModel.loadCachedArray(AppModel.messagesCacheKey, as: [SmsMessage].self)
    @Published var launchAtLoginEnabled = LaunchAgentManager.isEnabled()
    @Published var monitoringEnabled = UserDefaults.standard.object(forKey: "monitoringEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: "monitoringEnabled")
            monitoringEnabled ? startMonitoring() : stopMonitoring()
        }
    }
    @Published var monitorStatus = "Resident monitor ready."

    private var monitorTimer: Timer?
    private var isPollingCall = false
    private var isPollingCompanionCallState = false
    private var isPollingMessages = false
    private var incomingCallNotified = false
    private var activeCallNotified = false
    private var lastIncomingNotificationAt = Date.distantPast
    private var lastActiveCallNotificationAt = Date.distantPast
    private var activeCallPollPausedUntil = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: AppModel.activeCallPollPausedUntilKey))
    private var activeCallPollMinimumResumeAt = Date.distantPast
    private var lastSeenMessageDate = UserDefaults.standard.object(forKey: "lastSeenMessageDate") as? Int64 ?? 0
    private var messageBaselinePrimed = UserDefaults.standard.object(forKey: "lastSeenMessageDate") != nil
    private var lastMessagePoll = Date.distantPast
    private var notificationPanels: [NSPanel] = []
    private var messagePanels: [NSPanel] = []
    private var bleDiscoverer: CompanionBLEDiscoverer?
    private var companionCallStateFailureCount = 0
    private var lastHfpFallbackPoll = Date.distantPast

    let logPath = NSString(string: "~/opencall-mac/logs/hfp.log").expandingTildeInPath

    var helperPath: String {
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            return URL(fileURLWithPath: executableDir).appendingPathComponent("hfpctl").path
        }
        return NSString(string: "~/opencall-mac/build/OpenCall Mac.app/Contents/MacOS/hfpctl").expandingTildeInPath
    }

    var btHelperPath: String {
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            return URL(fileURLWithPath: executableDir).appendingPathComponent("btmeta").path
        }
        return NSString(string: "~/opencall-mac/build/OpenCall Mac.app/Contents/MacOS/btmeta").expandingTildeInPath
    }

    var selectedDeviceName: String {
        devices.first(where: { $0.address.lowercased() == selectedAddress.lowercased() })?.displayName ?? selectedAddress
    }

    private var isCompanionConfigured: Bool {
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isEmpty && base.contains("://") && !token.isEmpty
    }

    override init() {
        super.init()
        Self.shared = self
        requestNotificationAccess()
        refreshDevices()
        refreshLog()
        if !contacts.isEmpty || !recentCalls.isEmpty || !messages.isEmpty {
            syncStatus = "Loaded cached sync: \(contacts.count) contacts, \(recentCalls.count) recents, \(messages.count) SMS."
        }
        if monitoringEnabled { startMonitoring() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.autoConnectSelectedPhone() }
        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.sendTestNotification() }
        }
    }

    func refreshDevices() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = paired.map { device in
            PhoneDevice(id: device.addressString ?? UUID().uuidString,
                        name: device.name ?? "",
                        address: device.addressString ?? "")
        }
        .filter { !$0.address.isEmpty }
        .sorted { lhs, rhs in
            let l = lhs.displayName.lowercased()
            let r = rhs.displayName.lowercased()
            let lhsLooksPhone = l.contains("xiaomi") || l.contains("mix") || l.contains("phone")
            let rhsLooksPhone = r.contains("xiaomi") || r.contains("mix") || r.contains("phone")
            if lhsLooksPhone != rhsLooksPhone { return lhsLooksPhone && !rhsLooksPhone }
            return l < r
        }

        let saved = UserDefaults.standard.string(forKey: "selectedAddress") ?? selectedAddress
        if let remembered = devices.first(where: { $0.address.lowercased() == saved.lowercased() }) {
            selectedAddress = remembered.address
        } else if selectedAddress.isEmpty || !devices.contains(where: { $0.address.lowercased() == selectedAddress.lowercased() }) {
            if let xiaomi = devices.first(where: { $0.address.lowercased() == "bc-6a-d1-4d-f2-df" }) {
                selectedAddress = xiaomi.address
            } else if let first = devices.first {
                selectedAddress = first.address
            }
        }
        output = "Found \(devices.count) paired Bluetooth device(s). Selected: \(selectedDeviceName)."
    }

    func run(_ command: String, number: String? = nil) {
        let dialNumber = number?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == "dial", (dialNumber ?? "").isEmpty {
            output = "Enter a phone number before pressing Dial."
            return
        }
        if command == "dial", let dialNumber, companionCallStateAvailable {
            pauseAutomaticCallPollingForActiveCall(note: "after dialing through companion")
            busy = true
            output = "Dialing through Android companion…"
            sendCompanionDial(number: dialNumber) { result in
                switch result {
                case .success(let message):
                    self.busy = false
                    self.output = message
                    self.appendAppLog("Dial requested through Android companion; numberLength=\(dialNumber.count)")
                    self.pollCompanionCallStateForMonitor()
                case .failure(let error):
                    self.appendAppLog("Companion dial failed; falling back to native HFP: \(error.message)")
                    self.output = "Companion dial failed; trying native HFP…"
                    guard !self.selectedAddress.isEmpty else {
                        self.busy = false
                        self.output = "Companion dial failed and no Bluetooth phone is selected for HFP fallback."
                        return
                    }
                    self.runHfpHelper(command: command, helper: self.helperPath, address: self.selectedAddress, logPath: self.logPath, dialNumber: dialNumber)
                }
            }
            return
        }
        if (command == "answer" || command == "hangup"), isCompanionConfigured {
            if command == "answer" {
                pauseAutomaticCallPollingForActiveCall(note: "after answering through companion")
            }
            busy = true
            output = command == "answer" ? "Answering through Android companion…" : "Hanging up through Android companion…"
            sendCompanionCallControl(command: command) { result in
                switch result {
                case .success(let message):
                    self.busy = false
                    self.output = message
                    self.appendAppLog("\(command.capitalized) requested through Android companion")
                    if command == "hangup" {
                        self.resumeAutomaticCallPollingAfterCallEnded(logReason: "companion hangup")
                    }
                    self.pollCompanionCallStateForMonitor()
                case .failure(let error):
                    self.appendAppLog("Companion \(command) failed; falling back to native HFP: \(error.message)")
                    self.output = "Companion \(command) failed; trying native HFP…"
                    guard !self.selectedAddress.isEmpty else {
                        self.busy = false
                        self.output = "Companion \(command) failed and no Bluetooth phone is selected for HFP fallback."
                        return
                    }
                    if command == "hangup" {
                        self.resumeAutomaticCallPollingAfterCallEnded(logReason: "native HFP hangup fallback")
                    }
                    self.runHfpHelper(command: command, helper: self.helperPath, address: self.selectedAddress, logPath: self.logPath, dialNumber: nil)
                }
            }
            return
        }
        guard !selectedAddress.isEmpty else {
            output = command == "dial" ? "No companion configured and no Bluetooth phone selected for HFP fallback." : "No Bluetooth phone selected for native HFP control."
            return
        }
        if command == "answer" || command == "dial" {
            pauseAutomaticCallPollingForActiveCall(note: command == "answer" ? "after answering" : "after dialing")
        } else if command == "hangup" {
            resumeAutomaticCallPollingAfterCallEnded()
        }
        let helper = helperPath
        let address = selectedAddress
        let logPath = logPath
        busy = true
        output = "Running native HFP fallback \(command)…"
        runHfpHelper(command: command, helper: helper, address: address, logPath: logPath, dialNumber: dialNumber)
    }

    func call(_ number: String) {
        dialNumber = number
        run("dial", number: number)
    }

    private func runHfpHelper(command: String, helper: String, address: String, logPath: String, dialNumber: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runHelper(path: helper, command: command, address: address, logPath: logPath, number: dialNumber)
            DispatchQueue.main.async {
                self.busy = false
                let trimmed = Self.userVisibleHelperOutput(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                self.output = trimmed.isEmpty ? "Done (exit \(result.exitCode))." : trimmed
                self.refreshLog()
            }
        }
    }

    func refreshLog() {
        if let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            logText = lines.suffix(140).joined(separator: "\n")
        } else {
            logText = "No log yet: \(logPath)"
        }
    }

    func saveCompanionSettings() {
        UserDefaults.standard.set(companionURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "companionURL")
        UserDefaults.standard.set(companionToken.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "companionToken")
    }

    private static func loadCachedArray<T: Decodable>(_ key: String, as type: [T].Type) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(type, from: data)) ?? []
    }

    private func saveCachedArray<T: Encodable>(_ value: [T], key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAgentManager.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAgentManager.isEnabled()
            monitorStatus = launchAtLoginEnabled ? "Launch at login enabled." : "Launch at login disabled."
        } catch {
            launchAtLoginEnabled = LaunchAgentManager.isEnabled()
            monitorStatus = "Launch-at-login update failed: \(error.localizedDescription)"
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        monitoringEnabled = enabled
        monitorStatus = enabled ? "Resident monitor enabled." : "Resident monitor disabled."
    }

    func requestNotificationAccess() {
        AppDelegate.configureNotificationCategories()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error {
                    self.monitorStatus = "Notification permission error: \(error.localizedDescription)"
                } else if !granted {
                    self.monitorStatus = "Notifications are not allowed yet; using legacy macOS fallback."
                }
            }
        }
    }

    func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(timeInterval: 8, target: self, selector: #selector(monitorTimerFired(_:)), userInfo: nil, repeats: true)
        monitorStatus = "Resident monitor active."
        pollResidentStatus()
    }

    @objc private func monitorTimerFired(_ timer: Timer) {
        pollResidentStatus()
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        monitorStatus = "Resident monitor disabled."
    }

    func autoConnectSelectedPhone() {
        if companionCallStateAvailable {
            monitorStatus = "Using Android companion for call state; HFP fallback not needed."
            pollCompanionCallStateForMonitor()
            return
        }
        guard !selectedAddress.isEmpty else {
            monitorStatus = "No companion configured and no Bluetooth phone selected for HFP fallback."
            return
        }
        guard !isAutomaticCallPollingPaused else {
            monitorStatus = "Call audio protected: automatic HFP fallback polling is paused."
            return
        }
        pollCallState(reason: "Checking native HFP fallback for \(selectedDeviceName)…")
    }

    private var isAutomaticCallPollingPaused: Bool {
        if activeCallPollPausedUntil > Date() { return true }
        if UserDefaults.standard.object(forKey: Self.activeCallPollPausedUntilKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.activeCallPollPausedUntilKey)
        }
        return false
    }

    private func pauseAutomaticCallPollingForActiveCall(note: String) {
        let wasPaused = activeCallPollPausedUntil > Date()
        let until = Date().addingTimeInterval(Self.activeCallPollPauseSeconds)
        if until > activeCallPollPausedUntil {
            activeCallPollPausedUntil = until
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.activeCallPollPausedUntilKey)
        }
        if !wasPaused {
            activeCallPollMinimumResumeAt = Date().addingTimeInterval(45)
        }
        monitorStatus = "Call audio protected: automatic HFP fallback polling off; companion watches call state."
        appendAppLog("Automatic HFP fallback polling paused \(note) until \(Self.shortTime(activeCallPollPausedUntil)) to avoid stealing Bluetooth/AirPods audio")
    }

    func resumeAutomaticCallPollingNow() {
        resumeAutomaticCallPollingAfterCallEnded(logReason: "manual resume")
    }

    private func resumeAutomaticCallPollingAfterCallEnded(logReason: String = "hangup") {
        activeCallPollPausedUntil = Date.distantPast
        activeCallPollMinimumResumeAt = Date.distantPast
        UserDefaults.standard.removeObject(forKey: Self.activeCallPollPausedUntilKey)
        activeCallNotified = false
        incomingCallNotified = false
        monitorStatus = "Call monitor resumed."
        appendAppLog("Automatic HFP fallback polling resumed after \(logReason)")
    }

    nonisolated private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func pollResidentStatus() {
        guard monitoringEnabled else { return }
        refreshDevices()
        if companionCallStateAvailable {
            pollCompanionCallStateForMonitor()
        } else if !selectedAddress.isEmpty {
            if isAutomaticCallPollingPaused {
                monitorStatus = "Call audio protected: automatic HFP fallback polling is paused."
            } else {
                pollCallState(reason: nil)
            }
        } else {
            monitorStatus = "No companion configured; select a Bluetooth phone for HFP fallback."
        }
        if Date().timeIntervalSince(lastMessagePoll) >= 18 {
            lastMessagePoll = Date()
            pollMessagesForNotifications()
        }
    }

    private var companionCallStateAvailable: Bool {
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isEmpty && !base.contains("PHONE-IP") && base.contains("://") && !token.isEmpty
    }

    private func pollCompanionCallStateForMonitor() {
        guard !isPollingCompanionCallState else { return }
        isPollingCompanionCallState = true
        fetch("call-state", as: CallStateResponse.self) { result in
            self.isPollingCompanionCallState = false
            switch result {
            case .success(let response) where response.ok:
                self.handleCompanionCallState(response)
            case .success(let response):
                self.handleCompanionCallStateFailure(response.error ?? "unknown error")
            case .failure(let error):
                self.handleCompanionCallStateFailure(error.message)
            }
        }
    }

    private func handleCompanionCallState(_ response: CallStateResponse) {
        companionCallStateFailureCount = 0
        let state = (response.state ?? "unknown").lowercased()
        let now = Date()
        if response.offhook == true || state == "offhook" || state == "active" {
            incomingCallNotified = false
            activeCallNotified = true
            lastActiveCallNotificationAt = now
            pauseAutomaticCallPollingForActiveCall(note: "while companion reports offhook")
            return
        }
        if response.ringing == true || state == "ringing" {
            pauseAutomaticCallPollingForActiveCall(note: "while companion reports ringing")
            let rawNumber = response.incomingNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
            let callerLabel = contactLabel(forPhoneNumber: rawNumber)
            let shouldNotifyIncoming = !incomingCallNotified || now.timeIntervalSince(lastIncomingNotificationAt) > 20
            if shouldNotifyIncoming {
                incomingCallNotified = true
                lastIncomingNotificationAt = now
                let subtitle = callerLabel ?? selectedDeviceName
                let body = callerLabel == nil ? "OpenCall detected an incoming mobile call." : "Ringing on \(selectedDeviceName)."
                appendAppLog("Incoming call detected by Android companion; requesting notification")
                postNotification(title: "Incoming call", subtitle: subtitle, body: body, identifier: "opencall.incoming-call.\(Int(now.timeIntervalSince1970))", kind: .incomingCall)
            }
            monitorStatus = callerLabel == nil ? "Incoming call detected by companion." : "Incoming call from \(callerLabel!)."
            return
        }
        if response.idle == true || state == "idle" {
            incomingCallNotified = false
            activeCallNotified = false
            if isAutomaticCallPollingPaused {
                if Date() >= activeCallPollMinimumResumeAt {
                    resumeAutomaticCallPollingAfterCallEnded(logReason: "companion call-state idle")
                    monitorStatus = "Phone idle by companion; fallback HFP monitor available."
                } else {
                    monitorStatus = "Phone idle; keeping fallback HFP monitor paused briefly."
                }
            } else {
                monitorStatus = "Phone idle by companion; HFP fallback not needed."
            }
            return
        }
        handleCompanionCallStateFailure("unknown call state: \(state)")
    }

    private func handleCompanionCallStateFailure(_ message: String) {
        companionCallStateFailureCount += 1
        if isAutomaticCallPollingPaused {
            monitorStatus = "Call audio protected; companion call-state unavailable: \(message)"
            return
        }
        guard !selectedAddress.isEmpty else {
            monitorStatus = "Companion call-state unavailable; no Bluetooth phone selected for HFP fallback."
            return
        }
        let failuresReady = companionCallStateFailureCount >= Self.companionFailuresBeforeHfpFallback
        let cooldownReady = Date().timeIntervalSince(lastHfpFallbackPoll) >= Self.hfpFallbackPollCooldown
        guard failuresReady && cooldownReady else {
            monitorStatus = "Companion call-state unavailable; waiting before HFP fallback."
            if companionCallStateFailureCount == 1 {
                appendAppLog("Companion call-state unavailable; not using HFP fallback yet: \(message)")
            }
            return
        }
        lastHfpFallbackPoll = Date()
        appendAppLog("Companion call-state unavailable after \(companionCallStateFailureCount) failures; using throttled HFP fallback: \(message)")
        pollCallState(reason: nil)
    }

    private func pollCallState(reason: String?) {
        guard !selectedAddress.isEmpty, !isPollingCall else { return }
        let helper = helperPath
        let address = selectedAddress
        let logPath = logPath
        isPollingCall = true
        if let reason { monitorStatus = reason }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.runHelper(path: helper, command: "status", address: address, logPath: logPath)
            DispatchQueue.main.async {
                self.isPollingCall = false
                guard result.exitCode == 0 else {
                    self.monitorStatus = "Phone monitor failed: \(result.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                    return
                }
                let text = result.text
                let incoming = text.contains("callSetupMode=1") || text.contains("ringAttempt=") || text.contains("incomingCallFrom=")
                let active = text.contains("isCallActive=1")
                let callerNumber = Self.machineValue(named: "INCOMING_NUMBER", in: text)
                let callerLabel = self.contactLabel(forPhoneNumber: callerNumber)
                let now = Date()
                let shouldNotifyIncoming = incoming && (!self.incomingCallNotified || now.timeIntervalSince(self.lastIncomingNotificationAt) > 20)
                let shouldNotifyActive = active && (!self.activeCallNotified || now.timeIntervalSince(self.lastActiveCallNotificationAt) > 60)
                if shouldNotifyIncoming {
                    self.incomingCallNotified = true
                    self.lastIncomingNotificationAt = now
                    self.appendAppLog("Incoming call detected; requesting notification")
                    let subtitle = callerLabel ?? self.selectedDeviceName
                    let body = callerLabel == nil ? "OpenCall detected an incoming mobile call." : "Ringing on \(self.selectedDeviceName)."
                    self.postNotification(title: "Incoming call", subtitle: subtitle, body: body, identifier: "opencall.incoming-call.\(Int(now.timeIntervalSince1970))", kind: .incomingCall)
                    self.monitorStatus = callerLabel == nil ? "Incoming call detected." : "Incoming call from \(subtitle)."
                } else if incoming {
                    self.appendAppLog("Incoming call still ringing; notification already sent/recently suppressed")
                    self.monitorStatus = callerLabel == nil ? "Incoming call detected." : "Incoming call from \(callerLabel!)."
                } else if shouldNotifyActive {
                    self.incomingCallNotified = false
                    self.activeCallNotified = true
                    self.lastActiveCallNotificationAt = now
                    self.appendAppLog("Active call detected; pausing automatic HFP polling to avoid changing Bluetooth audio route")
                    self.pauseAutomaticCallPollingForActiveCall(note: "after active-call detection")
                } else if active {
                    self.incomingCallNotified = false
                    self.pauseAutomaticCallPollingForActiveCall(note: "while call is active")
                } else {
                    self.incomingCallNotified = false
                    self.activeCallNotified = false
                    self.monitorStatus = "Monitoring \(self.selectedDeviceName)."
                }
            }
        }
    }

    private func pollMessagesForNotifications() {
        guard !isPollingMessages else { return }
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.contains("PHONE-IP"), !token.isEmpty else { return }
        isPollingMessages = true
        fetch("sms", as: SmsResponse.self, limit: 25) { result in
            self.isPollingMessages = false
            switch result {
            case .success(let response) where response.ok:
                let fetched = response.messages ?? []
                self.messages = fetched
                self.saveCachedArray(fetched, key: Self.messagesCacheKey)
                let newest = fetched.map(\.date).max() ?? self.lastSeenMessageDate
                if !self.messageBaselinePrimed {
                    self.messageBaselinePrimed = true
                    self.lastSeenMessageDate = max(self.lastSeenMessageDate, newest)
                    UserDefaults.standard.set(self.lastSeenMessageDate, forKey: "lastSeenMessageDate")
                    return
                }
                let newIncoming = fetched
                    .filter { $0.type == "inbox" && $0.date > self.lastSeenMessageDate }
                    .sorted { $0.date < $1.date }
                for message in newIncoming.prefix(3) {
                    let sender = self.contactLabel(forPhoneNumber: message.address) ?? "Unknown sender"
                    self.postNotification(title: "New mobile message", subtitle: sender, body: self.notificationSnippet(message.body), identifier: "opencall.sms.\(message.id)", kind: .sms, sms: message)
                }
                if newIncoming.count > 3 {
                    self.postNotification(title: "New mobile messages", subtitle: self.selectedDeviceName, body: "\(newIncoming.count) new SMS messages received.", identifier: "opencall.sms.summary.\(newest)", kind: .smsSummary)
                }
                if newest > self.lastSeenMessageDate {
                    self.lastSeenMessageDate = newest
                    UserDefaults.standard.set(newest, forKey: "lastSeenMessageDate")
                }
            case .success(let response):
                self.monitorStatus = "Message monitor failed: \(response.error ?? "unknown error")"
            case .failure(let error):
                self.monitorStatus = "Message monitor failed: \(error.message)"
            }
        }
    }

    private func notificationSnippet(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= 120 { return clean }
        return String(clean.prefix(117)) + "…"
    }

    func contactLabel(forPhoneNumber number: String?) -> String? {
        guard let number else { return nil }
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let name = contactName(forPhoneNumber: clean) { return name }
        if let recentName = recentCalls.first(where: { Self.phoneNumbersMatch(clean, $0.number) && ($0.name?.isEmpty == false) })?.name {
            return recentName
        }
        return clean
    }

    private func contactName(forPhoneNumber number: String) -> String? {
        for contact in contacts {
            guard !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if contact.numbers.contains(where: { Self.phoneNumbersMatch(number, $0.number) }) {
                return contact.name
            }
        }
        return nil
    }

    nonisolated static func normalizedPhoneNumber(_ number: String) -> String {
        var digits = number.filter { $0.isNumber }
        while digits.hasPrefix("00") { digits.removeFirst(2) }
        return digits
    }

    nonisolated static func phoneNumbersMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedPhoneNumber(lhs)
        let right = normalizedPhoneNumber(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shortest = min(left.count, right.count)
        guard shortest >= 7 else { return false }
        return left.hasSuffix(right) || right.hasSuffix(left)
    }

    func sendTestNotification() {
        postNotification(title: "OpenCall notifications working", subtitle: selectedDeviceName, body: "This is a test Mac notification from OpenCall.", identifier: "opencall.test.\(Int(Date().timeIntervalSince1970))")
    }

    private func postNotification(title: String,
                                  subtitle: String,
                                  body: String,
                                  identifier: String,
                                  kind: OpenCallNotificationKind = .generic,
                                  sms: SmsMessage? = nil) {
        appendAppLog("Notification requested: \(title) id=\(identifier)")

        var userInfo: [String: Any] = [
            "kind": kind.rawValue,
            "identifier": identifier
        ]
        if let sms {
            userInfo["smsId"] = sms.id
            userInfo["smsAddress"] = sms.address
            userInfo["smsBody"] = sms.body
            userInfo["smsDate"] = sms.date
            userInfo["smsType"] = sms.type
            userInfo["smsRead"] = sms.read
        }

        // Use several system delivery paths, then always show our own small
        // floating banner. Notification Center can silently suppress unsigned
        // LSUIElement apps, but the in-app banner is under our control.
        let legacy = NSUserNotification()
        legacy.identifier = identifier
        legacy.title = title
        legacy.subtitle = subtitle
        legacy.informativeText = body
        legacy.soundName = NSUserNotificationDefaultSoundName
        legacy.userInfo = userInfo
        if kind == .incomingCall {
            legacy.hasActionButton = true
            legacy.actionButtonTitle = "Answer"
            legacy.otherButtonTitle = "Decline"
            legacy.additionalActions = [NSUserNotificationAction(identifier: OpenCallNotificationAction.decline, title: "Decline")]
        }
        NSUserNotificationCenter.default.deliver(legacy)
        appendAppLog("NSUserNotification delivered: \(identifier)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = "OpenCall"
        content.userInfo = userInfo
        switch kind {
        case .incomingCall:
            content.categoryIdentifier = OpenCallNotificationCategory.incomingCall
        case .sms, .smsSummary:
            content.categoryIdentifier = OpenCallNotificationCategory.sms
        default:
            break
        }
        let request = UNNotificationRequest(identifier: identifier + ".un", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
                if let error {
                    self.appendAppLog("UNUserNotification failed: \(error.localizedDescription)")
                    self.monitorStatus = "Notification fallback used: \(error.localizedDescription)"
                } else {
                    self.appendAppLog("UNUserNotification queued: \(identifier)")
                }
            }
        }

        deliverAppleScriptNotification(title: title, subtitle: subtitle, body: body)
        showFloatingNotification(title: title, subtitle: subtitle, body: body, kind: kind, sms: sms)
        NSSound(named: NSSound.Name("Glass"))?.play()
        monitorStatus = "Notification sent: \(title)"
    }

    private func showFloatingNotification(title: String,
                                          subtitle: String,
                                          body: String,
                                          kind: OpenCallNotificationKind,
                                          sms: SmsMessage? = nil) {
        var panelRef: NSPanel?
        let hasCallActions = kind == .incomingCall
        let height: CGFloat = hasCallActions ? 146 : 106
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: height),
                            styleMask: [.borderless],
                            backing: .buffered,
                            defer: false)
        panelRef = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        panel.hidesOnDeactivate = false

        let dismiss = { [weak self] in
            guard let self, let panel = panelRef else { return }
            self.closeNotificationPanel(panel)
        }

        let tapAction: (() -> Void)? = {
            if let sms {
                return { [weak self] in
                    self?.openSmsMessage(sms)
                    dismiss()
                }
            }
            if kind == .smsSummary {
                return { [weak self] in
                    self?.syncMessages()
                    self?.showMainWindow()
                    dismiss()
                }
            }
            return nil
        }()

        let answerAction: (() -> Void)? = hasCallActions ? { [weak self] in
            self?.appendAppLog("Incoming-call banner Answer tapped")
            self?.run("answer")
            dismiss()
        } : nil

        let declineAction: (() -> Void)? = hasCallActions ? { [weak self] in
            self?.appendAppLog("Incoming-call banner Decline tapped")
            self?.run("hangup")
            dismiss()
        } : nil

        panel.contentView = NSHostingView(rootView: NotificationBannerView(title: title,
                                                                            subtitle: subtitle,
                                                                            message: body,
                                                                            height: height,
                                                                            onTap: tapAction,
                                                                            primaryActionTitle: hasCallActions ? "Answer" : nil,
                                                                            primaryAction: answerAction,
                                                                            secondaryActionTitle: hasCallActions ? "Decline" : nil,
                                                                            secondaryAction: declineAction))

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(min(notificationPanels.count, 3)) * (height + 12)
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 410, y: screen.maxY - height - 18 - offset))
        notificationPanels.append(panel)
        panel.orderFrontRegardless()
        appendAppLog("Floating banner shown: \(title)")

        DispatchQueue.main.asyncAfter(deadline: .now() + (hasCallActions ? 30 : 20)) { [weak panel, weak self] in
            guard let panel, let self else { return }
            self.closeNotificationPanel(panel)
        }
    }

    private func closeNotificationPanel(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.close()
        notificationPanels.removeAll { $0 === panel }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "OpenCall Mac" || $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func openSmsMessage(_ message: SmsMessage) {
        appendAppLog("Opening SMS notification: id=\(message.id)")
        showMainWindow()
        showSmsMessageWindow(message)
    }

    private func showSmsMessageWindow(_ message: SmsMessage) {
        var panelRef: NSPanel?
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panelRef = panel
        panel.title = "OpenCall SMS"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let close = { [weak self] in
            guard let self, let panel = panelRef else { return }
            panel.orderOut(nil)
            panel.close()
            self.messagePanels.removeAll { $0 === panel }
        }
        let senderDisplay = contactLabel(forPhoneNumber: message.address) ?? (message.address.isEmpty ? "Unknown sender" : message.address)
        panel.contentView = NSHostingView(rootView: SmsMessageDetailView(message: message,
                                                                         senderDisplayName: senderDisplay,
                                                                         onCall: { [weak self] in self?.call(message.address) },
                                                                         onReply: { [weak self] text, done in
                                                                             self?.sendSmsReply(to: message.address, text: text, completion: done)
                                                                         },
                                                                         onClose: close))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.center()
        panel.setFrameOrigin(NSPoint(x: max(screen.minX + 20, screen.midX - 260), y: max(screen.minY + 20, screen.midY - 235)))
        messagePanels.append(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func handleNotificationResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        appendAppLog("Notification response: action=\(actionIdentifier) info=\(userInfo["kind"] ?? "unknown")")
        switch actionIdentifier {
        case OpenCallNotificationAction.answer:
            run("answer")
            return
        case OpenCallNotificationAction.decline:
            run("hangup")
            return
        default:
            break
        }

        guard let kindValue = userInfo["kind"] as? String,
              let kind = OpenCallNotificationKind(rawValue: kindValue) else {
            showMainWindow()
            return
        }
        switch kind {
        case .sms:
            if let message = Self.smsMessage(from: userInfo) {
                openSmsMessage(message)
            } else {
                showMainWindow()
            }
        case .smsSummary:
            syncMessages()
            showMainWindow()
        default:
            showMainWindow()
        }
    }

    func handleLegacyNotificationActivation(_ notification: NSUserNotification) {
        switch notification.activationType {
        case .actionButtonClicked:
            appendAppLog("Legacy notification Answer clicked")
            run("answer")
        case .additionalActionClicked:
            if notification.additionalActivationAction?.identifier == OpenCallNotificationAction.decline {
                appendAppLog("Legacy notification Decline clicked")
                run("hangup")
            }
        case .contentsClicked:
            handleNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: notification.userInfo ?? [:])
        default:
            break
        }
    }

    nonisolated private static func smsMessage(from userInfo: [AnyHashable: Any]) -> SmsMessage? {
        guard let id = userInfo["smsId"] as? String,
              let address = userInfo["smsAddress"] as? String,
              let body = userInfo["smsBody"] as? String else { return nil }
        let date: Int64
        if let value = userInfo["smsDate"] as? Int64 {
            date = value
        } else if let value = userInfo["smsDate"] as? NSNumber {
            date = value.int64Value
        } else {
            date = Int64(Date().timeIntervalSince1970 * 1000)
        }
        let type = userInfo["smsType"] as? String ?? "inbox"
        let read = (userInfo["smsRead"] as? Bool) ?? (userInfo["smsRead"] as? NSNumber)?.boolValue ?? false
        return SmsMessage(id: id, address: address, body: body, date: date, type: type, read: read)
    }

    private func deliverAppleScriptNotification(title: String, subtitle: String, body: String) {
        let escapedTitle = Self.appleScriptLiteral(title)
        let escapedSubtitle = Self.appleScriptLiteral(subtitle)
        let escapedBody = Self.appleScriptLiteral(body)
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" subtitle \"\(escapedSubtitle)\" sound name \"Glass\""
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let errorText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 {
                        self.appendAppLog("AppleScript notification delivered: \(title)")
                    } else {
                        self.appendAppLog("AppleScript notification failed: exit=\(task.terminationStatus) \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendAppLog("AppleScript notification failed to launch: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendAppLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let line = "[\(formatter.string(from: Date()))] OpenCallMac: \(message)\n"
        let url = URL(fileURLWithPath: logPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) { try handle.write(contentsOf: data) }
                try handle.close()
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("OpenCall log write failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func appleScriptLiteral(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    func discoverCompanionByBluetooth() {
        busy = true
        syncStatus = "Discovering companion over Bluetooth LE…"
        appendAppLog("Bluetooth companion discovery started with in-app BLE scan")
        let discoverer = CompanionBLEDiscoverer(timeout: 20) { [weak self] result in
            guard let self else { return }
            self.bleDiscoverer = nil
            switch result {
            case .success(let text):
                self.busy = false
                self.applyCompanionMetadata(text, source: "Bluetooth LE")
            case .failure(let error):
                self.appendAppLog("BLE companion discovery failed: \(error.localizedDescription)")
                guard !self.selectedAddress.isEmpty else {
                    self.busy = false
                    self.syncStatus = "Bluetooth LE discovery failed: \(error.localizedDescription). Select a paired phone for classic Bluetooth fallback."
                    return
                }
                self.syncStatus = "BLE failed; trying classic Bluetooth fallback…"
                self.discoverCompanionByClassicBluetooth(bleError: error.localizedDescription)
            }
        }
        bleDiscoverer = discoverer
        discoverer.start()
    }

    private func discoverCompanionByClassicBluetooth(bleError: String) {
        let address = selectedAddress
        let helper = btHelperPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try companionClassicMetadata(address: address, timeout: 24)
                DispatchQueue.main.async {
                    self.busy = false
                    self.applyCompanionMetadata(text, source: "classic Bluetooth")
                }
            } catch {
                let inAppClassic = error.localizedDescription
                // Last-resort legacy helper fallback for older macOS behavior. Tahoe usually
                // needs the in-app path above because btmeta is a separate Bluetooth client.
                let result = Self.runBluetoothHelper(path: helper, address: address, mode: "classic", timeout: 18)
                DispatchQueue.main.async {
                    self.busy = false
                    guard result.exitCode == 0 else {
                        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        let helperClassic = message.isEmpty ? "helper exit \(result.exitCode)" : message
                        self.syncStatus = "Bluetooth discovery failed. BLE: \(bleError); Classic: \(inAppClassic); Helper: \(helperClassic)"
                        self.appendAppLog("Classic Bluetooth companion discovery failed after BLE failure. inApp=\(inAppClassic); helper=\(helperClassic)")
                        return
                    }
                    guard let jsonLine = result.stdout.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }) else {
                        self.syncStatus = "Classic Bluetooth helper returned no metadata after in-app classic failed: \(inAppClassic)"
                        return
                    }
                    self.applyCompanionMetadata(String(jsonLine), source: "classic Bluetooth helper")
                }
            }
        }
    }

    private func applyCompanionMetadata(_ jsonLine: String, source: String) {
        do {
            let metadata = try JSONDecoder().decode(CompanionMetadata.self, from: Data(jsonLine.utf8))
            guard metadata.ok != false,
                  let url = metadata.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
                  let token = metadata.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                syncStatus = "Bluetooth discovery returned incomplete metadata."
                appendAppLog("Bluetooth discovery returned incomplete metadata via \(source)")
                return
            }
            companionURL = url
            companionToken = token
            saveCompanionSettings()
            syncStatus = "Discovered OpenCall Companion over \(source). URL/token filled."
            appendAppLog("Discovered OpenCall Companion over \(source); url=\(url)")
            syncHealth()
        } catch {
            syncStatus = "Bluetooth discovery decode failed: \(error.localizedDescription)"
            appendAppLog("Bluetooth discovery decode failed via \(source): \(error.localizedDescription)")
        }
    }

    func syncHealth() {
        saveCompanionSettings()
        syncStatus = "Checking companion health…"
        fetch("health", as: HealthResponse.self, requiresToken: false) { result in
            switch result {
            case .success(let health):
                let missing = (health.missingPermissions ?? []).joined(separator: ", ")
                let bt = health.bluetoothRunning == true ? "BT discovery on" : "BT discovery off"
                self.syncStatus = "Companion \(health.running == true ? "running" : "reachable") on port \(health.port ?? 0); \(bt). Missing: \(missing.isEmpty ? "none" : missing)."
            case .failure(let error):
                self.syncStatus = "Health failed: \(error)"
            }
        }
    }

    func syncContacts() {
        saveCompanionSettings()
        syncStatus = "Syncing contacts…"
        fetch("contacts", as: ContactsResponse.self) { result in
            switch result {
            case .success(let response) where response.ok:
                self.contacts = response.contacts ?? []
                self.saveCachedArray(self.contacts, key: Self.contactsCacheKey)
                self.syncStatus = "Loaded \(self.contacts.count) contacts."
            case .success(let response):
                self.syncStatus = "Contacts failed: \(response.error ?? "unknown error")"
            case .failure(let error):
                self.syncStatus = "Contacts failed: \(error)"
            }
        }
    }

    func syncCalls() {
        saveCompanionSettings()
        syncStatus = "Syncing recent calls…"
        fetch("calls", as: CallsResponse.self, limit: 100) { result in
            switch result {
            case .success(let response) where response.ok:
                self.recentCalls = response.calls ?? []
                self.saveCachedArray(self.recentCalls, key: Self.recentCallsCacheKey)
                self.syncStatus = "Loaded \(self.recentCalls.count) recent calls."
            case .success(let response):
                self.syncStatus = "Recent calls failed: \(response.error ?? "unknown error")"
            case .failure(let error):
                self.syncStatus = "Recent calls failed: \(error)"
            }
        }
    }

    func syncMessages() {
        saveCompanionSettings()
        syncStatus = "Syncing SMS messages…"
        fetch("sms", as: SmsResponse.self, limit: 100) { result in
            switch result {
            case .success(let response) where response.ok:
                self.messages = response.messages ?? []
                self.saveCachedArray(self.messages, key: Self.messagesCacheKey)
                self.syncStatus = "Loaded \(self.messages.count) SMS messages."
            case .success(let response):
                self.syncStatus = "Messages failed: \(response.error ?? "unknown error")"
            case .failure(let error):
                self.syncStatus = "Messages failed: \(error)"
            }
        }
    }

    func syncAll() {
        syncHealth()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.syncContacts() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { self.syncCalls() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.syncMessages() }
    }

    func sendCompanionDial(number: String, completion: @escaping (Result<String, SyncError>) -> Void) {
        let cleanNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNumber.isEmpty else {
            completion(.failure(SyncError("No dial number.")))
            return
        }
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, base.contains("://") else {
            completion(.failure(SyncError("Enter companion URL first.")))
            return
        }
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            completion(.failure(SyncError("Enter companion token first.")))
            return
        }
        var components = URLComponents(string: base + "/dial")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            completion(.failure(SyncError("Bad companion URL.")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-OpenCall-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["number": cleanNumber], options: [])
        } catch {
            completion(.failure(SyncError(error.localizedDescription)))
            return
        }
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(SyncError(error.localizedDescription))) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(SyncError("no response"))) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(DialResponse.self, from: data)
                DispatchQueue.main.async {
                    if decoded.ok && decoded.dialed == true {
                        completion(.success("Dial requested through Android companion."))
                    } else {
                        completion(.failure(SyncError(decoded.error ?? "unknown dial error")))
                    }
                }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(.failure(SyncError(raw.isEmpty ? error.localizedDescription : raw))) }
            }
        }.resume()
    }

    func sendCompanionCallControl(command: String, completion: @escaping (Result<String, SyncError>) -> Void) {
        let endpoint: String
        switch command {
        case "answer": endpoint = "answer"
        case "hangup": endpoint = "hangup"
        default:
            completion(.failure(SyncError("Unsupported companion call-control command.")))
            return
        }
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, base.contains("://") else {
            completion(.failure(SyncError("Enter companion URL first.")))
            return
        }
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            completion(.failure(SyncError("Enter companion token first.")))
            return
        }
        var components = URLComponents(string: base + "/" + endpoint)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            completion(.failure(SyncError("Bad companion URL.")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-OpenCall-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(SyncError(error.localizedDescription))) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                DispatchQueue.main.async { completion(.failure(SyncError("no response"))) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(CallControlResponse.self, from: data)
                DispatchQueue.main.async {
                    if decoded.ok && command == "answer" && decoded.answerRequested == true {
                        completion(.success("Answer requested through Android companion."))
                    } else if decoded.ok && command == "hangup" && decoded.hangupRequested == true {
                        let message = decoded.ended == false ? "Hangup requested; Android reported no active call." : "Hangup requested through Android companion."
                        completion(.success(message))
                    } else {
                        completion(.failure(SyncError(decoded.error ?? "unknown \(command) error")))
                    }
                }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? ""
                let message = raw.isEmpty ? error.localizedDescription : raw
                DispatchQueue.main.async { completion(.failure(SyncError(statusCode > 0 ? "HTTP \(statusCode): \(message)" : message))) }
            }
        }.resume()
    }

    func sendSmsReply(to number: String, text: String, completion: @escaping (String) -> Void) {
        let cleanNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNumber.isEmpty else {
            completion("No recipient number.")
            return
        }
        guard !cleanText.isEmpty else {
            completion("Type a reply first.")
            return
        }
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, base.contains("://") else {
            completion("Enter companion URL first.")
            return
        }
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            completion("Enter companion token first.")
            return
        }
        var components = URLComponents(string: base + "/send-sms")
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "number", value: cleanNumber),
            URLQueryItem(name: "text", value: cleanText)
        ]
        guard let url = components?.url else {
            completion("Bad companion URL.")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-OpenCall-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        appendAppLog("Sending SMS reply to [number]; chars=\(cleanText.count)")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async {
                    self.appendAppLog("SMS reply failed: \(error.localizedDescription)")
                    completion("Send failed: \(error.localizedDescription)")
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async {
                    self.appendAppLog("SMS reply failed: no response")
                    completion("Send failed: no response")
                }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SendSmsResponse.self, from: data)
                DispatchQueue.main.async {
                    if decoded.ok && decoded.sent == true {
                        self.appendAppLog("SMS reply sent; parts=\(decoded.parts ?? 1)")
                        self.syncMessages()
                        completion("Sent")
                    } else {
                        let message = decoded.error ?? "unknown error"
                        self.appendAppLog("SMS reply failed: \(message)")
                        completion("Send failed: \(message)")
                    }
                }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.appendAppLog("SMS reply decode failed: \(error.localizedDescription) \(raw)")
                    completion("Send failed: \(raw.isEmpty ? error.localizedDescription : raw)")
                }
            }
        }.resume()
    }

    private func fetch<T: Decodable>(_ endpoint: String, as type: T.Type, limit: Int? = nil, requiresToken: Bool = true, completion: @escaping (Result<T, SyncError>) -> Void) {
        let base = companionURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, base.contains("://") else {
            completion(.failure(SyncError("Enter companion URL, e.g. http://PHONE-IP:9096")))
            return
        }
        var components = URLComponents(string: base + "/" + endpoint)
        var items: [URLQueryItem] = []
        let token = companionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresToken {
            guard !token.isEmpty else {
                completion(.failure(SyncError("Enter companion token")))
                return
            }
            items.append(URLQueryItem(name: "token", value: token))
        }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else {
            completion(.failure(SyncError("Bad companion URL")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-OpenCall-Token") }
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(SyncError(error.localizedDescription))) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(SyncError("No response data"))) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                DispatchQueue.main.async { completion(.success(decoded)) }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(.failure(SyncError("Decode failed: \(error.localizedDescription) \(raw)"))) }
            }
        }.resume()
    }

    nonisolated static func runBluetoothHelper(path: String, address: String, mode: String = "auto", timeout: Int = 10) -> ProcessOutput {
        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--mode", mode, "--address", address, "--timeout", String(timeout)]
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ProcessOutput(stdout: out, stderr: err, exitCode: task.terminationStatus)
        } catch {
            return ProcessOutput(stdout: "", stderr: "Failed to run btmeta: \(error.localizedDescription)", exitCode: 1)
        }
    }

    nonisolated static func machineValue(named key: String, in text: String) -> String? {
        let prefix = "OPENCALL_\(key)_B64="
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix) else { continue }
            let encoded = String(line.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8) else { continue }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    nonisolated static func userVisibleHelperOutput(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("OPENCALL_") }
            .joined(separator: "\n")
    }

    nonisolated static func runHelper(path: String, command: String, address: String, logPath: String, number: String? = nil) -> CommandResult {
        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        var arguments = [command, "--address", address, "--log", logPath]
        if let number, !number.isEmpty { arguments += ["--number", number] }
        task.arguments = arguments
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandResult(text: [out, err].filter { !$0.isEmpty }.joined(separator: "\n"), exitCode: task.terminationStatus)
        } catch {
            return CommandResult(text: "Failed to run hfpctl: \(error.localizedDescription)", exitCode: 1)
        }
    }
}

struct NotificationBannerView: View {
    let title: String
    let subtitle: String
    let message: String
    let height: CGFloat
    let onTap: (() -> Void)?
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: title.localizedCaseInsensitiveContains("message") ? "message.fill" : "phone.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(primaryActionTitle == nil ? 2 : 1)
                }
                Spacer(minLength: 0)
            }

            if primaryActionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: 12) {
                    if let primaryActionTitle, let primaryAction {
                        Button(primaryActionTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .font(.headline)
                            .frame(width: 142, height: 40)
                    }
                    if let secondaryActionTitle, let secondaryAction {
                        Button(role: .destructive, action: secondaryAction) {
                            Text(secondaryActionTitle)
                                .font(.headline)
                                .frame(width: 142, height: 40)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 52)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, primaryActionTitle == nil ? 10 : 4)
        .frame(width: 390, height: height, alignment: .topLeading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if primaryActionTitle == nil { onTap?() }
        }
    }
}

struct SmsMessageDetailView: View {
    let message: SmsMessage
    let senderDisplayName: String
    let onCall: () -> Void
    let onReply: (_ text: String, _ done: @escaping (String) -> Void) -> Void
    let onClose: () -> Void

    @State private var replyText = ""
    @State private var replyStatus = ""
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SMS Message")
                        .font(.title3.weight(.semibold))
                    Text(senderDisplayName)
                        .font(.headline)
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
                    .controlSize(.large)
            }

            ScrollView {
                Text(message.body.isEmpty ? "(empty message)" : message.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(minHeight: 120, maxHeight: 155)

            VStack(alignment: .leading, spacing: 6) {
                Text("Reply")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $replyText)
                    .font(.body)
                    .frame(height: 86)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !replyStatus.isEmpty {
                    Text(replyStatus)
                        .font(.caption)
                        .foregroundStyle(replyStatus == "Sent" ? .green : .secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(minWidth: 88)
                }
                .controlSize(.large)

                Button { onCall() } label: {
                    Label("Call", systemImage: "phone.fill")
                        .frame(minWidth: 88)
                }
                .controlSize(.large)
                .disabled(message.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer(minLength: 0)

                Button {
                    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        replyStatus = "Type a reply first."
                        return
                    }
                    isSending = true
                    replyStatus = "Sending…"
                    onReply(text) { status in
                        replyStatus = status
                        isSending = false
                        if status == "Sent" { replyText = "" }
                    }
                } label: {
                    Label(isSending ? "Sending" : "Send reply", systemImage: "paperplane.fill")
                        .frame(minWidth: 128)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 0)
        }
        .padding(.top, 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .frame(width: 520, height: 470)
    }

    private var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(message.date) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    private var diagnosticModel: AppModel?
    static func configureNotificationCategories() {
        let answer = UNNotificationAction(identifier: OpenCallNotificationAction.answer,
                                          title: "Answer",
                                          options: [.foreground])
        let decline = UNNotificationAction(identifier: OpenCallNotificationAction.decline,
                                           title: "Decline",
                                           options: [.destructive])
        let incoming = UNNotificationCategory(identifier: OpenCallNotificationCategory.incomingCall,
                                              actions: [answer, decline],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        let sms = UNNotificationCategory(identifier: OpenCallNotificationCategory.sms,
                                         actions: [],
                                         intentIdentifiers: [],
                                         options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([incoming, sms])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.configureNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        NSUserNotificationCenter.default.delegate = self
        if CommandLine.arguments.contains("--test-bluetooth-discovery") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let model = AppModel.shared ?? AppModel()
                if AppModel.shared == nil { self.diagnosticModel = model }
                model.discoverCompanionByBluetooth()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            AppModel.shared?.handleNotificationResponse(actionIdentifier: action, userInfo: info)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        Task { @MainActor in
            AppModel.shared?.handleLegacyNotificationActivation(notification)
        }
    }
}

@main
struct OpenCallMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenCall Mac", id: "main") {
            ContentView(model: model).frame(width: 900, height: 830)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarIconView: View {
    var body: some View {
        Image(systemName: "phone.fill")
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show OpenCall") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text(model.selectedDeviceName.isEmpty ? "No phone selected" : model.selectedDeviceName)
        Text(model.monitorStatus)
        Divider()
        Button("Check phone state") { model.autoConnectSelectedPhone() }
        Button("Resume fallback monitor") { model.resumeAutomaticCallPollingNow() }
        Button("Sync All") { model.syncAll() }
        Button("Auto via Bluetooth") { model.discoverCompanionByBluetooth() }
        Button("Test Notification") { model.sendTestNotification() }
        Divider()
        Toggle("Monitor calls/messages", isOn: Binding(get: { model.monitoringEnabled }, set: { model.setMonitoringEnabled($0) }))
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit OpenCall") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            phonePicker
            dialControls
            callControls
            residentControls
            companionPanel
            logPanel
        }
        .padding(18)
        .onReceive(timer) { _ in model.refreshLog() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenCall Mac")
                    .font(.title2.weight(.semibold))
                Text("Android companion-first phone control + native HFP fallback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var phonePicker: some View {
        HStack {
            Picker("Phone", selection: $model.selectedAddress) {
                ForEach(model.devices) { device in Text(device.displayName).tag(device.address) }
            }
            .frame(maxWidth: .infinity)
            Button("Refresh Devices") { model.refreshDevices() }
        }
    }

    private var dialControls: some View {
        HStack(spacing: 12) {
            TextField("Phone number", text: $model.dialNumber)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { model.run("dial", number: model.dialNumber) }
            Button { model.run("dial", number: model.dialNumber) } label: {
                Label("Dial", systemImage: "phone.arrow.up.right").frame(width: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy || model.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var callControls: some View {
        HStack(spacing: 12) {
            Button { model.run("status") } label: {
                Label("Check HFP fallback", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.busy)

            Button { model.run("answer") } label: {
                Label("Answer", systemImage: "phone.fill.arrow.up.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy)

            Button(role: .destructive) { model.run("hangup") } label: {
                Label("Hang Up", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.busy)
        }
    }

    private var residentControls: some View {
        GroupBox("Resident Companion Monitor") {
            HStack(spacing: 14) {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Monitor calls/messages", isOn: Binding(get: { model.monitoringEnabled }, set: { model.setMonitoringEnabled($0) }))
                Button("Check phone now") { model.autoConnectSelectedPhone() }
                    .disabled(model.busy)
                Button("Resume fallback monitor") { model.resumeAutomaticCallPollingNow() }
                Button("Test notification") { model.sendTestNotification() }
                Spacer()
                Text(model.monitorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    private var companionPanel: some View {
        GroupBox("Android Companion") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("http://PHONE-IP:9096", text: $model.companionURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    TextField("Token", text: $model.companionToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 230)
                }
                HStack(spacing: 10) {
                    Button("Auto via Bluetooth") { model.discoverCompanionByBluetooth() }
                        .disabled(model.busy)
                    Button("Health") { model.syncHealth() }
                    Button("Contacts") { model.syncContacts() }
                    Button("Recents") { model.syncCalls() }
                    Button("Messages") { model.syncMessages() }
                    Button("Sync All") { model.syncAll() }
                    Spacer()
                    Text(model.syncStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TabView {
                    contactsView.tabItem { Text("Contacts (\(model.contacts.count))") }
                    recentsView.tabItem { Text("Recents (\(model.recentCalls.count))") }
                    messagesView.tabItem { Text("Messages (\(model.messages.count))") }
                }
                .frame(height: 260)
            }
        }
    }

    private var contactsView: some View {
        List(model.contacts) { contact in
            VStack(alignment: .leading, spacing: 5) {
                Text(contact.name.isEmpty ? "Unnamed" : contact.name).font(.headline)
                ForEach(contact.numbers) { number in
                    HStack {
                        Text(number.label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(number.number).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Call") { model.call(number.number) }
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var recentsView: some View {
        List(model.recentCalls) { call in
            let displayName = call.name?.isEmpty == false ? call.name! : (model.contactLabel(forPhoneNumber: call.number) ?? call.number)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName).font(.headline)
                    Text("\(call.type) • \(formatMillis(call.date)) • \(call.duration)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(call.number).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                Button("Call") { model.call(call.number) }
            }
            .padding(.vertical, 3)
        }
    }

    private var messagesView: some View {
        List(model.messages) { message in
            let sender = model.contactLabel(forPhoneNumber: message.address) ?? message.address
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(sender).font(.caption.weight(.semibold)).textSelection(.enabled)
                    Text(message.type).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatMillis(message.date)).font(.caption).foregroundStyle(.secondary)
                    Button("Call") { model.call(message.address) }
                }
                Text(message.body).lineLimit(3).textSelection(.enabled)
            }
            .padding(.vertical, 3)
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last command")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 92)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Log: ~/opencall-mac/logs/hfp.log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload Log") { model.refreshLog() }
            }
            ScrollView {
                Text(model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 115)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func formatMillis(_ millis: Int64) -> String {
        guard millis > 0 else { return "unknown" }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0).formatted(date: .abbreviated, time: .shortened)
    }
}
