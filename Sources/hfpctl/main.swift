import Foundation
import IOBluetooth

let defaultPhoneAddress = "bc-6a-d1-4d-f2-df"
let defaultLogPath = NSString(string: "~/opencall-mac/logs/hfp.log").expandingTildeInPath

func redact(_ value: String) -> String {
    value.replacingOccurrences(
        of: #"(?<![A-Za-z0-9_])(?:\+?\d[\d\s().-]{4,}\d)(?![A-Za-z0-9_])"#,
        with: "[number]",
        options: .regularExpression
    )
}

func iorString(_ result: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: result))
}

func machineValue(_ key: String, _ value: String) {
    guard let data = value.data(using: .utf8) else { return }
    print("OPENCALL_\(key)_B64=\(data.base64EncodedString())")
    fflush(stdout)
}

func looksLikePhoneNumber(_ text: String) -> Bool {
    let digits = text.filter { $0.isNumber }
    return digits.count >= 5 && digits.count <= 18
}

final class Logger {
    let path: String

    init(path: String) {
        self.path = NSString(string: path).expandingTildeInPath
        let dir = URL(fileURLWithPath: self.path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func log(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let entry = "[\(time)] hfpctl: \(redact(line))"
        print(entry)
        guard let data = (entry + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class HFPCTL: NSObject {
    let command: String
    let address: String
    let logger: Logger
    let number: String?
    var hf: IOBluetoothHandsFreeDevice?
    var callSetupMode = "unknown"
    var lastIncomingNumber: String?

    init(command: String, address: String, logPath: String, number: String? = nil) {
        self.command = command
        self.address = address.lowercased()
        self.logger = Logger(path: logPath)
        self.number = number
    }

    func run() -> Int32 {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = paired.first(where: { ($0.addressString ?? "").lowercased() == address }) ?? IOBluetoothDevice(addressString: address) else {
            logger.log("No Bluetooth device found for \(address)")
            return 2
        }

        logger.log("Device \(device.name ?? "Android phone") / \(device.addressString ?? address) connected=\(device.isConnected())")
        let openResult = device.openConnection()
        logger.log("ACL openConnection result: \(iorString(openResult))")

        hf = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        guard let hf else {
            logger.log("Failed to create IOBluetoothHandsFreeDevice")
            return 3
        }

        // HFP call control/status features. Deliberately avoid codec-negotiation bits.
        hf.supportedFeatures = 0x7f
        logger.log("Created HFP object; supportedFeatures=0x7f; calling connect()")
        hf.connect()
        logger.log("HFP isConnected immediately: \(hf.isConnected)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.logStatusRequests()
        }

        switch command {
        case "answer":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in self?.answer() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { exit(0) }
        case "hangup":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.hangup() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { exit(0) }
        case "dial":
            guard let number, !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.log("Dial requested without a number")
                return 65
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in self?.dial(number: number) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { exit(0) }
        case "status", "prepare":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
        default:
            logger.log("Unknown command \(command)")
            return 64
        }

        RunLoop.main.run()
        return 0
    }

    func logStatusRequests() {
        guard let hf else { return }
        logger.log("HFP isConnected after 0.9s: \(hf.isConnected); requesting currentCallList/subscriberNumber")
        hf.currentCallList()
        hf.subscriberNumber()
    }

    func answer() {
        guard let hf else { return }
        if !hf.isConnected {
            logger.log("Before answer: isConnected=false, calling connect() again and sending answer anyway")
            hf.connect()
        }
        logger.log("Sending native acceptCallOnPhone(); callSetupMode=\(callSetupMode)")
        hf.acceptCallOnPhone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let hf = self.hf else { return }
            if self.callSetupMode == "1" || self.callSetupMode == "unknown" {
                self.logger.log("Fallback sending native acceptCall(); callSetupMode=\(self.callSetupMode)")
                hf.acceptCall()
            } else {
                self.logger.log("No fallback acceptCall needed; callSetupMode=\(self.callSetupMode)")
            }
        }
    }

    func hangup() {
        guard let hf else { return }
        logger.log("Sending native endCall()")
        hf.endCall()
    }

    func dial(number: String) {
        guard let hf else { return }
        let cleanNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hf.isConnected {
            logger.log("Before dial: isConnected=false, calling connect() again and dialing anyway")
            hf.connect()
        }
        logger.log("Sending native dialNumber([number])")
        hf.dialNumber(cleanNumber)
    }

    func rememberIncomingNumber(_ number: String) {
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != lastIncomingNumber else { return }
        lastIncomingNumber = clean
        machineValue("INCOMING_NUMBER", clean)
    }

    static func extractPhoneNumber(from value: Any) -> String? {
        if let string = value as? String, looksLikePhoneNumber(string) { return string }
        if let number = value as? NSNumber {
            let string = number.stringValue
            if looksLikePhoneNumber(string) { return string }
        }
        if let dict = value as? NSDictionary {
            let preferredKeys = ["number", "phoneNumber", "PhoneNumber", "kIOBluetoothHandsFreeCallNumber"]
            for key in preferredKeys {
                if let item = dict[key], let found = extractPhoneNumber(from: item) { return found }
            }
            for item in dict.allValues {
                if let found = extractPhoneNumber(from: item) { return found }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let found = extractPhoneNumber(from: item) { return found }
            }
        }
        return nil
    }

    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, isServiceAvailable available: NSNumber) { logger.log("event isServiceAvailable=\(available)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, isCallActive active: NSNumber) { logger.log("event isCallActive=\(active)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, callSetupMode mode: NSNumber) { callSetupMode = mode.stringValue; logger.log("event callSetupMode=\(mode) (1=incoming)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, callHoldState state: NSNumber) { logger.log("event callHoldState=\(state)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, signalStrength strength: NSNumber) { logger.log("event signalStrength=\(strength)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, batteryCharge charge: NSNumber) { logger.log("event batteryCharge=\(charge)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, incomingCallFrom number: String) { callSetupMode = "1"; rememberIncomingNumber(number); logger.log("event incomingCallFrom=[number]") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, ringAttempt attempt: NSNumber) { callSetupMode = "1"; logger.log("event ringAttempt=\(attempt)") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, currentCall call: NSDictionary) {
        if let number = Self.extractPhoneNumber(from: call) { rememberIncomingNumber(number) }
        logger.log("event currentCall=\(call.description)")
    }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, subscriberNumber number: String) { logger.log("event subscriberNumber=[number]") }
    @objc func handsFree(_ device: IOBluetoothHandsFreeDevice, unhandledResultCode resultCode: String) { logger.log("event unhandledResultCode=\(resultCode)") }
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
var address = defaultPhoneAddress
var logPath = defaultLogPath
var number: String?
var index = 0
while index < args.count {
    switch args[index] {
    case "--address" where index + 1 < args.count:
        address = args[index + 1]
        index += 2
    case "--log" where index + 1 < args.count:
        logPath = args[index + 1]
        index += 2
    case "--number" where index + 1 < args.count:
        number = args[index + 1]
        index += 2
    default:
        index += 1
    }
}
exit(HFPCTL(command: command, address: address, logPath: logPath, number: number).run())
