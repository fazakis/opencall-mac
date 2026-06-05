import Foundation
import IOBluetooth
import CoreBluetooth

let serviceUUIDString = "9fb61f76-4a9d-4f97-a6be-2a97f6f7f2b1"
let characteristicUUIDString = "9fb61f77-4a9d-4f97-a6be-2a97f6f7f2b1"

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}


final class BLEDiscoverer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: serviceUUIDString)
    private let characteristicUUID = CBUUID(string: characteristicUUIDString)
    private let queue = DispatchQueue(label: "local.opencall.btmeta.ble")
    private let semaphore = DispatchSemaphore(value: 0)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var result: Result<String, Error>?
    private var startedAt = Date()
    private var discoveredAdvertisements = 0
    private var probedAdvertisements = 0
    private var probingUnadvertisedPeripheral = false
    private var triedPeripheralIDs = Set<UUID>()
    private var usingTargetedScan = false

    func discover(timeout: TimeInterval) throws -> String {
        startedAt = Date()
        central = CBCentralManager(delegate: self, queue: queue)
        let wait = semaphore.wait(timeout: .now() + timeout)
        if wait == .timedOut {
            central?.stopScan()
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            throw CLIError("Timed out waiting for BLE OpenCall Companion metadata; saw \(discoveredAdvertisements) BLE advertisement(s), probed \(probedAdvertisements) peripheral(s)")
        }
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        case .none: throw CLIError("BLE discovery ended without metadata")
        }
    }

    private func finish(_ value: Result<String, Error>) {
        if result != nil { return }
        result = value
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        semaphore.signal()
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
        guard result == nil, let central else { return }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        probingUnadvertisedPeripheral = false
        usingTargetedScan = false
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unsupported:
            finish(.failure(CLIError("BLE is unsupported on this Mac")))
        case .unauthorized:
            finish(.failure(CLIError("Bluetooth permission denied for BLE discovery")))
        case .poweredOff:
            finish(.failure(CLIError("Bluetooth is powered off")))
        default:
            if Date().timeIntervalSince(startedAt) > 2 {
                finish(.failure(CLIError("Bluetooth not ready for BLE discovery (state \(central.state.rawValue))")))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowUUIDs = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let solicitedUUIDs = (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let advertisedMatch = usingTargetedScan
                || serviceUUIDs.contains(serviceUUID)
                || overflowUUIDs.contains(serviceUUID)
                || solicitedUUIDs.contains(serviceUUID)
                || serviceData.keys.contains(serviceUUID)
        if advertisedMatch {
            useDiscoveredPeripheral(peripheral, central: central, advertisedMatch: true)
            return
        }
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
        finish(.failure(CLIError("BLE connect failed: \(error?.localizedDescription ?? "unknown")")))
    }


    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if probingUnadvertisedPeripheral {
            resumeScanningAfterProbeMiss()
            return
        }
        if let error {
            finish(.failure(CLIError("BLE disconnected before metadata read: \(error.localizedDescription)")))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { finish(.failure(CLIError("BLE service discovery failed: \(error.localizedDescription)"))); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            if probingUnadvertisedPeripheral {
                resumeScanningAfterProbeMiss()
                return
            }
            finish(.failure(CLIError("BLE OpenCall Companion service not found")))
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { finish(.failure(CLIError("BLE characteristic discovery failed: \(error.localizedDescription)"))); return }
        guard let ch = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            finish(.failure(CLIError("BLE OpenCall metadata characteristic not found")))
            return
        }
        peripheral.readValue(for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(CLIError("BLE metadata read failed: \(error.localizedDescription)"))); return }
        guard let data = characteristic.value, !data.isEmpty else {
            finish(.failure(CLIError("BLE metadata characteristic was empty")))
            return
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            finish(.failure(CLIError("BLE metadata was not UTF-8 text")))
            return
        }
        finish(.success(text))
    }
}

final class SDPWaiter: NSObject {
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

final class RFCOMMReader: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var data = Data()
    var closed = false

    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel, data dataPointer: UnsafeMutableRawPointer, length dataLength: Int) {
        data.append(dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength)
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        closed = true
    }
}

func parseArgs() -> [String: String] {
    var out: [String: String] = [:]
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                out[key] = args[index + 1]
                index += 2
            } else {
                out[key] = "true"
                index += 1
            }
        } else {
            index += 1
        }
    }
    return out
}

func uuidBytes(_ uuid: String) throws -> [UInt8] {
    let hex = uuid.replacingOccurrences(of: "-", with: "")
    guard hex.count == 32 else { throw CLIError("Bad UUID: \(uuid)") }
    var bytes: [UInt8] = []
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { throw CLIError("Bad UUID byte in \(uuid)") }
        bytes.append(byte)
        idx = next
    }
    return bytes
}

func makeSDPUUID(_ uuid: String) throws -> IOBluetoothSDPUUID {
    let bytes = try uuidBytes(uuid)
    return IOBluetoothSDPUUID(data: Data(bytes))
}


func uuid16Value(_ uuid: IOBluetoothSDPUUID) -> UInt16? {
    guard let compact = uuid.getWithLength(2) else { return nil }
    let data = Data(referencing: compact)
    guard data.count == 2 else { return nil }
    return (UInt16(data[0]) << 8) | UInt16(data[1])
}

func parseRFCOMMChannelID(from element: IOBluetoothSDPDataElement) -> BluetoothRFCOMMChannelID? {
    guard let children = element.getArrayValue() as? [IOBluetoothSDPDataElement] else { return nil }
    if children.count >= 2,
       let uuid = children[0].getUUIDValue(),
       uuid16Value(uuid) == 0x0003,
       let number = children[1].getNumberValue() {
        let channel = number.uint8Value
        if channel > 0 { return BluetoothRFCOMMChannelID(channel) }
    }
    for child in children {
        if let channel = parseRFCOMMChannelID(from: child) { return channel }
    }
    return nil
}

func manuallyParsedRFCOMMChannelID(from service: IOBluetoothSDPServiceRecord) -> BluetoothRFCOMMChannelID? {
    // Attribute 0x0004 is ProtocolDescriptorList. On Tahoe, getRFCOMMChannelID()
    // can fail even when the Android RFCOMM service record is present, so parse
    // the nested SDP data element sequence ourselves.
    guard let protocolList = service.getAttributeDataElement(BluetoothSDPServiceAttributeID(0x0004)) else { return nil }
    return parseRFCOMMChannelID(from: protocolList)
}

func deviceFor(address rawAddress: String) throws -> IOBluetoothDevice {
    let wanted = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !wanted.isEmpty else { throw CLIError("Missing --address") }
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    if let match = paired.first(where: { ($0.addressString ?? "").lowercased() == wanted }) {
        return match
    }
    if let device = IOBluetoothDevice(addressString: wanted) { return device }
    throw CLIError("Bluetooth device not found: \(rawAddress)")
}

func isOpenCallMetadata(_ text: String) -> Bool {
    text.contains("OpenCall Companion") && text.contains("token") && text.contains("url")
}

func readRFCOMMMetadata(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, timeout: TimeInterval, requireOpenCall: Bool) throws -> String {
    let reader = RFCOMMReader()
    var channel: IOBluetoothRFCOMMChannel?
    let openStatus = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: reader)
    guard openStatus == kIOReturnSuccess, let channel else {
        throw CLIError(String(format: "RFCOMM open failed on channel %u: 0x%08x", channelID, openStatus))
    }
    defer { _ = channel.close() }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && !reader.closed && !reader.data.contains(0x0a) {
        RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.05), deadline))
    }
    guard !reader.data.isEmpty else { throw CLIError("No metadata received on RFCOMM channel \(channelID)") }
    let text = String(data: reader.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw CLIError("Metadata was empty on RFCOMM channel \(channelID)") }
    if requireOpenCall && !isOpenCallMetadata(text) {
        throw CLIError("RFCOMM channel \(channelID) did not return OpenCall metadata")
    }
    return text
}

func scanRFCOMMChannels(device: IOBluetoothDevice, until deadline: Date) throws -> String {
    var failures: [String] = []
    // Android normally assigns a dynamic RFCOMM server channel. Tahoe can fail to
    // expose that channel through SDP even while the server is listening, so try
    // the legal RFCOMM server-channel range and accept only our JSON metadata.
    for raw in 1...30 {
        if Date() >= deadline { break }
        let channelID = BluetoothRFCOMMChannelID(raw)
        let remaining = max(0.15, deadline.timeIntervalSinceNow)
        let perChannel = min(0.75, remaining)
        do {
            let text = try readRFCOMMMetadata(device: device, channelID: channelID, timeout: perChannel, requireOpenCall: true)
            return text
        } catch {
            if failures.count < 5 { failures.append("ch\(raw): \(error)") }
        }
    }
    let detail = failures.isEmpty ? "no channels attempted" : failures.joined(separator: "; ")
    throw CLIError("OpenCall RFCOMM channel scan failed (\(detail))")
}

func discoverClassic(address: String, timeout: TimeInterval) throws -> String {
    let device = try deviceFor(address: address)
    let sdpUUID = try makeSDPUUID(serviceUUIDString)
    let deadline = Date().addingTimeInterval(timeout)
    var errors: [String] = []
    var channelID: BluetoothRFCOMMChannelID?

    // Android's listenUsingRfcommWithServiceRecord() does publish SDP, but Tahoe
    // may time out or return the service without a usable RFCOMM channel. Keep
    // SDP as a fast path, then fall back to direct RFCOMM channel discovery.
    let waiter = SDPWaiter()
    let started = device.performSDPQuery(waiter)
    if started == kIOReturnSuccess {
        waiter.wait(timeout: min(8, max(3, timeout * 0.35)))
        if waiter.done, waiter.status == kIOReturnSuccess {
            if let service = device.getServiceRecord(for: sdpUUID) {
                var sdpChannel = BluetoothRFCOMMChannelID(0)
                let channelStatus = service.getRFCOMMChannelID(&sdpChannel)
                if channelStatus == kIOReturnSuccess, sdpChannel > 0 {
                    channelID = sdpChannel
                } else if let parsed = manuallyParsedRFCOMMChannelID(from: service), parsed > 0 {
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
            return try readRFCOMMMetadata(device: device, channelID: channelID, timeout: max(1, deadline.timeIntervalSinceNow), requireOpenCall: false)
        } catch {
            errors.append("RFCOMM channel \(channelID) from SDP failed: \(error)")
        }
    }

    do {
        return try scanRFCOMMChannels(device: device, until: deadline)
    } catch {
        errors.append("RFCOMM scan failed: \(error)")
        throw CLIError(errors.joined(separator: "; "))
    }
}

func main() -> Int32 {
    do {
        let args = parseArgs()
        let timeout = TimeInterval(args["timeout"] ?? "10") ?? 10
        let address = args["address"] ?? ""
        let mode = (args["mode"] ?? "auto").lowercased()
        var errors: [String] = []

        if mode == "auto" || mode == "ble" {
            do {
                let json = try BLEDiscoverer().discover(timeout: timeout)
                print(json)
                return 0
            } catch {
                errors.append("BLE: \(error)")
                if mode == "ble" { throw CLIError(errors.joined(separator: "; ")) }
            }
        }

        if mode == "auto" || mode == "classic" || mode == "rfcomm" {
            do {
                let json = try discoverClassic(address: address, timeout: timeout)
                print(json)
                return 0
            } catch {
                errors.append("Classic: \(error)")
                throw CLIError(errors.joined(separator: "; "))
            }
        }

        throw CLIError("Unknown --mode \(mode). Use auto, ble, or classic.")
    } catch {
        fputs("btmeta: \(error)\n", stderr)
        return 1
    }
}

exit(main())
