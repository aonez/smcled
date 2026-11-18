// smcled.swift — AppleSMC power LED CLI for Apple Silicon Mac mini and Studio
// No Apple-private headers, third-party dependencies, kext, or SIP changes.
// Verified on Macmini9,1: white PWM and three amber presets.
// Confirmed: LSLN controls brightness on steady amber (tested at 10 and 50).
// Optional sunrise/sunset automation uses the system-selected city (no TCC prompt).

import Foundation
import Dispatch
#if os(macOS)
import Darwin
import IOKit
#endif

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func fourCC(_ string: String) throws -> UInt32 {
    let data = Array(string.utf8)
    guard data.count == 4, data.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
        throw ToolError("SMC key must contain exactly four printable ASCII bytes")
    }
    return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

func fourCCString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    return String(decoding: bytes, as: UTF8.self)
}

func putU32(_ number: UInt32, at offset: Int, in buffer: inout [UInt8]) {
    // The IOKit SMC struct uses little-endian 32-bit fields on supported macOS architectures.
    for i in 0..<4 { buffer[offset + i] = UInt8(truncatingIfNeeded: number >> UInt32(i * 8)) }
}

func getU32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(buffer[offset + $1]) << UInt32($1 * 8)) }
}

// Avoid direct use of the global C `stderr` pointer (Swift 6 strict concurrency).
func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func modelID() -> String {
    #if os(macOS)
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var chars = [CChar](repeating: 0, count: size)
    let status = chars.withUnsafeMutableBufferPointer { ptr in
        sysctlbyname("hw.model", ptr.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { return "unknown" }
    return String(cString: chars)
    #else
    return "unsupported host"
    #endif
}

struct KeyInfo {
    let size: UInt32
    let type: String
    let attributes: UInt8
    var writable: Bool { attributes & 0x40 != 0 }
    var readable: Bool { attributes & 0x80 != 0 }
}

final class SMC {
    #if os(macOS)
    private var connection: io_connect_t = 0
    #endif

    init() throws {
        #if os(macOS)
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw ToolError("AppleSMC service not found") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw ToolError(String(format: "IOServiceOpen failed: 0x%08X", result)) }
        #else
        throw ToolError("AppleSMC requires macOS")
        #endif
    }

    deinit {
        #if os(macOS)
        if connection != 0 { IOServiceClose(connection) }
        #endif
    }

    // SMCKeyData is 80 bytes, with key at 0, size at 28,
    // type at 32, attrs at 36, result at 40, command at 42,
    // index at 44, and data payload at 48.
    private func call(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count == 80 else { throw ToolError("Internal protocol size error") }
        #if os(macOS)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(connection, 2, inputPointer.baseAddress, 80,
                                          outputPointer.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ToolError(String(format: "SMC IOKit call failed: 0x%08X (permission or unsupported operation)", result))
        }
        guard outputSize == 80 else { throw ToolError("Unexpected SMC response size: \(outputSize)") }
        guard output[40] == 0 else {
            throw ToolError(String(format: "SMC rejected operation: result 0x%02X", output[40]))
        }
        return output
        #else
        throw ToolError("AppleSMC requires macOS")
        #endif
    }

    func info(_ key: String) throws -> KeyInfo {
        var input = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &input)
        input[42] = 9 // get key info
        let out = try call(input)
        return KeyInfo(size: getU32(out, at: 28), type: fourCCString(getU32(out, at: 32)), attributes: out[36])
    }

    func read(_ key: String) throws -> [UInt8] {
        let metadata = try info(key)
        guard metadata.size <= 32 else { throw ToolError("Key length exceeds SMC payload") }
        var input = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &input)
        putU32(metadata.size, at: 28, in: &input)
        input[42] = 5 // read value
        let out = try call(input)
        return Array(out[48..<(48 + Int(metadata.size))])
    }

    func keyAt(_ index: UInt32) throws -> String {
        var input = [UInt8](repeating: 0, count: 80)
        input[42] = 8 // enumerate key
        putU32(index, at: 44, in: &input)
        let out = try call(input)
        return fourCCString(getU32(out, at: 0))
    }

    func keyCount() throws -> UInt32 {
        let bytes = try read("#KEY")
        guard bytes.count == 4 else { throw ToolError("Invalid #KEY payload") }
        let big = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let little = bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if big > 0 && big < 100_000 { return big }
        if little > 0 && little < 100_000 { return little }
        throw ToolError("Implausible SMC key count: \(hex(bytes))")
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        guard (1...2).contains(bytes.count) else { throw ToolError("SMC writes must be 1 or 2 bytes") }
        var input = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &input)
        putU32(UInt32(bytes.count), at: 28, in: &input)
        input[42] = 6 // write value
        for (index, byte) in bytes.enumerated() { input[48 + index] = byte }
        _ = try call(input)
    }
}

// Non-destructive hardware fingerprinting. Matching SMC metadata is evidence
// of a compatible interface, NOT proof that the physical LED responds.
// New models remain guarded until their behavior has been observed on hardware.
enum CompatibilityLevel: String {
    case verified = "verified on physical hardware"
    case fullCandidate = "full LED key-set candidate (unverified)"
    case brightnessCandidate = "brightness-register candidate (channel support unknown)"
    case unavailable = "no recognized LED control interface"
}

private let brightnessSignature: [(String, UInt32, String, Bool, Bool)] = [
    ("LSLN", 2, "ui16", true, true)
]
private let fullSignature: [(String, UInt32, String, Bool, Bool)] = [
    ("LSLN", 2, "ui16", true, true),
    ("LSSB", 2, "hex_", false, true),
    ("LSRB", 1, "flag", false, true),
    ("LSCS", 1, "ui8 ", true, false),
    ("LS0P", 2, "ui16", true, false),
    ("LS1P", 2, "ui16", true, false)
]

func signatureMatches(_ actual: [String: KeyInfo],
                      specs: [(String, UInt32, String, Bool, Bool)]) -> Bool {
    specs.allSatisfy { key, size, type, readable, writable in
        guard let info = actual[key] else { return false }
        return info.size == size && info.type == type &&
               (!readable || info.readable) && (!writable || info.writable)
    }
}

func compatibilityLevel(_ model: String, _ keys: [String: KeyInfo]) -> CompatibilityLevel {
    let full = signatureMatches(keys, specs: fullSignature)
    if physicallyTestedDesktops.contains(model) && full { return .verified }
    if full { return .fullCandidate }
    if signatureMatches(keys, specs: brightnessSignature) { return .brightnessCandidate }
    return .unavailable
}

func readCompatibilityKeys(_ smc: SMC) -> [String: KeyInfo] {
    // Missing/inaccessible keys simply fail to match the signature.
    let names = ["LSLN", "LSSB", "LSRB", "LSCS", "LS0P", "LS1P"]
    var result: [String: KeyInfo] = [:]
    for name in names { result[name] = try? smc.info(name) }
    return result
}

func reportCompatibility() throws {
    let smc = try SMC()
    let model = modelID()
    if model == "Macmini8,1" {
        print("Mac model: \(model)")
        print("SMC LED interface: Intel T2 (off/full-white/normal-white physically verified on one unit)")
        print("  Available: --off, --intel-full, --reset, --intel-restore, --white [0...255], --intel-brightness <0...255>")
        print("  Manual 0...255 levels are experimental; installation and amber/color commands remain blocked.")
        try intelSILStatus()
        return
    }
    let keys = readCompatibilityKeys(smc)
    let level = compatibilityLevel(model, keys)
    print("Mac model: \(model)")
    print("SMC LED interface: \(level.rawValue)")
    for (name, size, type, readable, writable) in fullSignature {
        if let info = keys[name] {
            let valid = info.size == size && info.type == type &&
                        (!readable || info.readable) && (!writable || info.writable)
            let attrs = String(format: "0x%02X", info.attributes)
            print("  \(name): \(valid ? "matches" : "different")" +
                  " (size=\(info.size), type=\(info.type.debugDescription), attrs=\(attrs))")
        } else { print("  \(name): unavailable") }
    }
    if let brightness = keys["LSLN"], brightness.readable,
       brightness.size == 2, let bytes = try? smc.read("LSLN") {
        print("Current brightness register: \(hex(bytes))")
        if bytes.count == 2 && bytes[0] != bytes[1] {
            print("  Note: LSLN bytes differ; their meaning on this Mac is unverified.")
            print("  The reversible brightness write test will refuse to run.")
            print("  Use --sample-brightness to inspect changes without writing.")
        }
    }
    if level == .verified {
        print("Standard LED commands available on the physically tested model.")
    } else if level == .unavailable {
        print("LED writes are blocked: required brightness metadata unavailable.")
    } else if level == .fullCandidate &&
              (supportedAppleSiliconDesktops.contains(model) || futureAppleSiliconDesktop(model)) {
        print("Untested Apple Silicon Mac mini/Studio: writes require --accept-untested-model.")
        print("Matching metadata does not prove physical LED behavior.")
    } else {
        print("Only explicit temporary diagnostics are available; normal LED writes are blocked.")
        print("Matching metadata does not prove physical LED behavior.")
    }
}

// Read-only sampling can show whether an unusual brightness register changes
// over time; it must not be used to infer the meaning of the two bytes.
func sampleBrightnessRegister() throws {
    let smc = try SMC()
    let info = try smc.info("LSLN")
    guard info.size == 2, info.type == "ui16", info.readable else {
        throw ToolError("LSLN is not a readable two-byte ui16 key")
    }
    print("Read-only LSLN samples on \(modelID()) (no SMC writes):")
    for i in 0..<10 {
        let bytes = try smc.read("LSLN")
        print(String(format: "+%.1fs", Double(i) * 0.5) + "  \(hex(bytes))")
        if i < 9 { Thread.sleep(forTimeInterval: 0.5) }
    }
    print("The samples do not establish how the bytes map to physical brightness.")
}

// Pure self-tests exercise the classification logic without touching AppleSMC.
func compatibilitySelfTest() throws {
    func key(_ size: UInt32, _ type: String, _ attrs: UInt8) -> KeyInfo {
        KeyInfo(size: size, type: type, attributes: attrs)
    }
    let full: [String: KeyInfo] = [
        "LSLN": key(2, "ui16", 0xC0),
        "LSSB": key(2, "hex_", 0x50),
        "LSRB": key(1, "flag", 0x50),
        "LSCS": key(1, "ui8 ", 0x90),
        "LS0P": key(2, "ui16", 0x80),
        "LS1P": key(2, "ui16", 0x80)
    ]
    let reduced = full.filter { ["LSLN", "LSSB", "LSRB"].contains($0.key) }
    var invalid = full
    invalid["LSLN"] = key(2, "ui16", 0x80) // read-only: no safe brightness test
    let cases: [(String, [String: KeyInfo], CompatibilityLevel)] = [
        ("Macmini9,1", full, .verified),
        ("Mac16,9", full, .verified),
        ("Mac14,3", full, .fullCandidate),
        ("Mac16,11", full, .fullCandidate),
        ("Mac13,2", full, .fullCandidate),
        ("Mac15,14", full, .fullCandidate),
        ("Macmini8,1", reduced, .brightnessCandidate),
        ("Macmini9,1", reduced, .brightnessCandidate),
        ("Mac16,9", invalid, .unavailable),
        ("unknown", [:], .unavailable)
    ]
    for (model, keys, expected) in cases {
        let actual = compatibilityLevel(model, keys)
        guard actual == expected else {
            throw ToolError("Compatibility self-test failed for \(model): expected \(expected.rawValue), got \(actual.rawValue)")
        }
        print("PASS: \(model) -> \(actual.rawValue)")
    }
    let original: [UInt8] = [0x2F, 0xFF]
    let first = intelProposedBytes(original, experiment:
        IntelLSLNExperiment(byte: .first, value: 0x20, label: "offline first"))
    let second = intelProposedBytes(original, experiment:
        IntelLSLNExperiment(byte: .second, value: 0x64, label: "offline second"))
    guard first == [0x20, 0xFF] && second == [0x2F, 0x64] &&
          original == [0x2F, 0xFF] else {
        throw ToolError("Intel LSLN byte-selection self-test failed")
    }
    print("PASS: Intel byte-selection logic preserves the other byte")
    guard looksLikeModernMacIdentifier("Mac17,9"),
          looksLikeModernMacIdentifier("Mac27,12"),
          !looksLikeModernMacIdentifier("Macmini8,1"),
          !looksLikeModernMacIdentifier("MacBookPro19,1"),
          !looksLikeModernMacIdentifier("Mac17,9-extra") else {
        throw ToolError("Future-model identifier syntax self-test failed")
    }
    print("PASS: future model ID syntax guard")
    print("Compatibility self-tests passed (no SMC access).")
}

// A system LaunchDaemon runs this same binary with --apply-installed.
// The binary and its preference live together in a root-owned directory.
private let installDirectory = "/Library/Application Support/smcled"
private let installedExecutable = installDirectory + "/smcled"
private let brightnessPreference = installDirectory + "/brightness"
private let modePreference = installDirectory + "/mode"
private let jobLabel = "dev.smcled.brightness"
private let daemonPlist = "/Library/LaunchDaemons/" + jobLabel + ".plist"
// A system-style PATH entry is a symlink to the privately installed executable.
// Never write into /usr/bin (protected by SIP).
private let cliParentDirectory = "/usr/local"
private let cliBinDirectory = "/usr/local/bin"
private let cliLink = cliBinDirectory + "/smcled"

func requireRoot() throws {
    #if os(macOS)
    guard geteuid() == 0 else { throw ToolError("This operation requires sudo/root") }
    #else
    throw ToolError("Installation requires macOS")
    #endif
}

func requireM1Mini() throws {
    guard modelID() == "Macmini9,1" else {
        throw ToolError("LED changes are only verified on Macmini9,1 (found \(modelID()))")
    }
}

// Apple-published model identifiers for Apple Silicon Mac mini and Mac Studio.
// Only Macmini9,1 and Mac16,9 have physically confirmed LED behavior.
private let supportedAppleSiliconDesktops: Set<String> = [
    "Macmini9,1", "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11",
    "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"
]
private let physicallyTestedDesktops: Set<String> = ["Macmini9,1", "Mac16,9"]

// Future Apple Silicon model IDs have no stable Mac mini/Studio prefix. For
// unknown IDs, require BOTH an explicit opt-in and system_profiler confirmation
// of the physical product family. The existing known IDs need no subprocess.
func looksLikeModernMacIdentifier(_ model: String) -> Bool {
    model.range(of: #"^Mac[0-9]+,[0-9]+$"#, options: .regularExpression) != nil
}

func futureAppleSiliconDesktop(_ model: String) -> Bool {
    #if os(macOS)
    guard looksLikeModernMacIdentifier(model) else { return false }
    var supported: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0) == 0,
          supported == 1 else { return false }

    // Avoid shell commands, user-controlled paths and localized text output.
    // system_profiler's JSON includes machine_model and machine_name.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType", "-json"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let completed = DispatchGroup()
    completed.enter()
    process.terminationHandler = { _ in completed.leave() }
    do { try process.run() } catch { return false }
    if completed.wait(timeout: .now() + 10) == .timedOut {
        if process.isRunning { process.terminate() }
        return false
    }
    guard process.terminationStatus == 0,
          let root = try? JSONSerialization.jsonObject(
            with: output.fileHandleForReading.readDataToEndOfFile()
          ) as? [String: Any],
          let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first,
          hardware["machine_model"] as? String == model,
          let family = hardware["machine_name"] as? String else { return false }
    return family == "Mac mini" || family == "Mac Studio"
    #else
    return false
    #endif
}

func requireSupportedLEDHost(smc existingSMC: SMC? = nil) throws {
    let model = modelID()
    if model == "Macmini8,1" {
        throw ToolError("Intel Mac mini LED encoding is unverified; regular LED writes remain disabled")
    }
    let knownModel = supportedAppleSiliconDesktops.contains(model)
    let acknowledged = CommandLine.arguments.contains("--accept-untested-model")
    if !knownModel {
        guard acknowledged else {
            throw ToolError("Unknown model \(model): requires --accept-untested-model after reviewing experimental hardware risks")
        }
        guard futureAppleSiliconDesktop(model) else {
            throw ToolError("Unknown model \(model): not verified as an Apple Silicon Mac mini or Mac Studio; refusing LED writes")
        }
    }
    // Every model, including a known one, must pass the complete SMC key
    // profile. Unknown future models additionally need plausible channel and
    // brightness readings before we write anything.
    let smc = try existingSMC ?? SMC()
    guard signatureMatches(readCompatibilityKeys(smc), specs: fullSignature) else {
        throw ToolError("SMC LED key metadata differs from the supported profile on \(model); refusing writes")
    }
    if !knownModel {
        let brightness = try smc.read("LSLN")
        let channel = try smc.read("LSCS")
        guard brightness.count == 2, brightness[0] == brightness[1],
              channel == [0] || channel == [1] else {
            throw ToolError("Unknown model \(model): LED state differs from the verified profile; refusing writes")
        }
    }
    guard physicallyTestedDesktops.contains(model) || acknowledged else {
        throw ToolError("\(model) is an untested Apple Silicon desktop. Rerun with --accept-untested-model after reviewing the warning")
    }
}

func brightnessNumber(_ string: String) throws -> UInt8 {
    guard !string.isEmpty, string.allSatisfy({ $0 >= "0" && $0 <= "9" }),
          let value = UInt8(string) else { throw ToolError("Brightness must be an integer from 0 through 255") }
    return value
}

func autoIntervalSeconds(_ string: String) throws -> Int {
    // Minimum 30 seconds avoids excessive process launches / SMC checks.
    guard !string.isEmpty, string.allSatisfy({ $0 >= "0" && $0 <= "9" }),
          let value = Int(string), (30...86_400).contains(value) else {
        throw ToolError("Automatic check interval must be an integer from 30 through 86400 seconds")
    }
    return value
}

// Firmware-supported LED presets physically verified on M1 Mac mini j274:
// 4 = constant amber; 8 = single amber flash; 9 = double amber flash.
// White is restored using LSRB, which was also tested on physical hardware.
enum LEDMode: String {
    case white
    case amber
    case amberBlink = "amber-blink"
    case amberDouble = "amber-double"

    var preset: UInt8? {
        switch self {
        case .white: return nil
        case .amber: return 4
        case .amberBlink: return 8
        case .amberDouble: return 9
        }
    }
}

func checkLEDKeys(_ smc: SMC, includeModes: Bool) throws {
    let keys: [(String, UInt32, String, Bool, Bool)] = includeModes
        ? [("LSLN", 2, "ui16", true, true),
           ("LSSB", 2, "hex_", false, true),
           ("LSRB", 1, "flag", false, true),
           ("LSCS", 1, "ui8 ", true, false),
           ("LS0P", 2, "ui16", true, false),
           ("LS1P", 2, "ui16", true, false)]
        : [("LSLN", 2, "ui16", true, true)]
    for (key, size, type, readable, writable) in keys {
        let info = try smc.info(key)
        guard info.size == size && info.type == type && (!readable || info.readable) &&
              (!writable || info.writable) else {
            throw ToolError("Unexpected SMC metadata for \(key) on this Mac; refusing LED write")
        }
    }
}

// LSRB restores the firmware's normal LED state asynchronously.
// Poll until channel 0 is active BEFORE applying white brightness, so a delayed
// channel transition does not override the requested value.
func restoreWhiteChannel(_ smc: SMC) throws {
    try smc.write("LSRB", bytes: [0])
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if try smc.read("LSCS") == [0], try smc.read("LS1P") == [0, 0] { return }
    }
    throw ToolError("SMC did not confirm restored white channel within 5 seconds; inspect LED")
}

// LSLN brightness was physically confirmed on white and steady amber.
// For amber, select the preset first, then apply brightness, matching the
// order used in the successful hardware test (--test-amber-brightness).
// Brightness on flashing amber presets is plausible but not yet hardware verified.
func applyKnownLED(_ smc: SMC, mode: LEDMode, brightness: UInt8? = nil) throws {
    try requireRoot()
    try requireSupportedLEDHost(smc: smc)
    try checkLEDKeys(smc, includeModes: true)
    switch mode {
    case .white:
        // When --white has no brightness argument, preserve the existing LSLN.
        let currentBrightness: [UInt8]
        if let brightness { currentBrightness = [brightness, brightness] }
        else { currentBrightness = try smc.read("LSLN") }
        try restoreWhiteChannel(smc)
        try smc.write("LSLN", bytes: currentBrightness)
    case .amber, .amberBlink, .amberDouble:
        try smc.write("LSSB", bytes: [mode.preset!, 0])
        if let brightness { try smc.write("LSLN", bytes: [brightness, brightness]) }
    }
}

// The legacy quick brightness operation is explicitly a white-mode operation.
func setKnownLEDBrightness(_ brightness: UInt8) throws {
    try requireRoot()
    try requireSupportedLEDHost()
    let smc = try SMC()
    try applyKnownLED(smc, mode: .white, brightness: brightness)
}

// Physically validated on one Macmini8,1 (T2, bridgeOS 24P6005):
// LSOO=0 -> LED off, LSOF=01, LSPV=00 00.
// LSOO=1 -> visibly full-bright white, LSPV=6B 08.
// LSRB=0 -> fades to normal white, LSPV=14 11, LSOF=00.
// This is an *independent* Intel protocol. No LSLN brightness values,
// Apple Silicon amber presets, or boot-time installations are enabled here.
// Conservative fingerprints restrict writes to the tested hardware state.
enum IntelSILState {
    case off, full, normal
}

func checkIntelSIL(_ smc: SMC) throws {
    try requireRoot()
    guard modelID() == "Macmini8,1" else {
        throw ToolError("Intel SIL controls are restricted to Macmini8,1")
    }
    let required: [(String, UInt32, String, Bool, Bool)] = [
        ("LSOO", 1, "flag", false, true),
        ("LSRB", 1, "flag", false, true),
        ("LSPV", 2, "ui16", true, false),
        ("LSOF", 1, "flag", true, false),
        ("LSLN", 2, "ui16", true, true),
        ("LSLB", 2, "ui16", true, true),
        ("LSSV", 2, "ui16", true, true),
        ("LS! ", 1, "ui8 ", true, true)
    ]
    for (key, size, type, readable, writable) in required {
        let info = try smc.info(key)
        guard info.size == size && info.type == type &&
              info.readable == readable && info.writable == writable else {
            throw ToolError("Unexpected Intel SMC key metadata for \(key); refusing write")
        }
    }
    // Exact state observed during physical tests. Fail closed on different
    // T2 firmware/hardware until the variation is separately investigated.
    guard try smc.read("LSLN") == [0x2F, 0xFF],
          try smc.read("LSSV") == [0x08, 0x6B],
          try smc.read("LS! ") == [0x00] else {
        throw ToolError("Intel SIL calibration differs from the tested unit; refusing write")
    }
}

// The Intel T2 SIL is a distinct controller path from Apple Silicon.
// 0...255 is mapped to the 16-bit LSLB full-on PWM preset using [v,v].
// Tests physically confirmed 08 00, 10 00, 20 00, 7F FF and FF FF,
// including repeatable dimming and recovery. Arbitrary levels remain
// experimental. Changes last until --reset, sleep/firmware reset or reboot;
// no LaunchDaemon or persistent preference is installed.
private let intelNormalPWM: [UInt8] = [0x14, 0x11]
private let intelDefaultLSLB: [UInt8] = [0xFF, 0xFF]
private let intelFullPWM: [UInt8] = [0x6B, 0x08]

func intelUnsigned16(_ bytes: [UInt8]) -> Int {
    Int(bytes[0]) * 256 + Int(bytes[1])
}

func intelPWMExpected(_ brightnessPreset: [UInt8]) -> Int {
    // Observed proportional relationship: full LSLB=FFFF -> LSPV=6B08.
    // Rounded integer approximation permits small fixed-point differences.
    (intelUnsigned16(brightnessPreset) * 0x6B08 + 0x7FFF) / 0xFFFF
}

func intelStableState(_ smc: SMC) throws -> ([UInt8], [UInt8], [UInt8]) {
    // Sample twice to avoid treating an active flash or fading transition as
    // a steady state. This is a guard, not proof that no external writer exists.
    let preset = try smc.read("LSLB")
    guard preset.count == 2 else { throw ToolError("Intel LSLB size differs") }
    let pwm = try smc.read("LSPV")
    let off = try smc.read("LSOF")
    Thread.sleep(forTimeInterval: 0.2)
    let pwmAgain = try smc.read("LSPV")
    let offAgain = try smc.read("LSOF")
    guard pwm == pwmAgain, off == offAgain else {
        throw ToolError("Intel LED output is changing (possibly fading or blinking); retry when stable")
    }
    let scaled = intelPWMExpected(preset)
    let isOff = off == [1] && pwm == [0, 0]
    let isNormal = off == [0] && pwm == intelNormalPWM
    let isOverride = off == [0] && pwm.count == 2 &&
                     abs(intelUnsigned16(pwm) - scaled) <= 3
    guard isOff || isNormal || isOverride else {
        throw ToolError("Intel LED state not recognized (LSLB=\(hex(preset)), LSPV=\(hex(pwm)), LSOF=\(hex(off))); refusing write")
    }
    return (preset, pwm, off)
}

func intelWaitFor(_ smc: SMC, targetPWM: [UInt8]?,
                  targetOff: [UInt8], maxSeconds: TimeInterval) throws -> [UInt8] {
    let deadline = Date().addingTimeInterval(maxSeconds)
    var pwm: [UInt8] = []
    var off: [UInt8] = []
    repeat {
        pwm = try smc.read("LSPV")
        off = try smc.read("LSOF")
        if off == targetOff, targetPWM == nil || pwm == targetPWM { return pwm }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    throw ToolError("Intel LED did not reach requested state within \(maxSeconds)s (LSPV=\(hex(pwm)), LSOF=\(hex(off)))")
}

func intelRestoreSystem(_ smc: SMC) throws {
    // Restore the *mode* first; restoring LSLB while full-on override is
    // active visibly pulses the LED at maximum brightness.
    try smc.write("LSRB", bytes: [0])
    _ = try intelWaitFor(smc, targetPWM: intelNormalPWM, targetOff: [0], maxSeconds: 6)
    if try smc.read("LSLB") != intelDefaultLSLB {
        try smc.write("LSLB", bytes: intelDefaultLSLB)
        guard try smc.read("LSLB") == intelDefaultLSLB else {
            throw ToolError("Intel LSLB factory preset restoration did not verify")
        }
    }
    let pwm = try smc.read("LSPV")
    let off = try smc.read("LSOF")
    guard pwm == intelNormalPWM, off == [0] else {
        throw ToolError("Intel normal PWM changed during restoration; inspect physical LED")
    }
}

func intelWriteBrightness(_ level: UInt8) throws {
    let smc = try SMC()
    try checkIntelSIL(smc)
    let _ = try intelStableState(smc)
    if level == 0 {
        // Use physically verified off command; 0-valued LSLB full-on
        // semantics have not been tested on this T2 firmware.
        try smc.write("LSOO", bytes: [0])
        _ = try intelWaitFor(smc, targetPWM: [0, 0], targetOff: [1], maxSeconds: 2)
        print("Intel LED off (level 0). Run --reset for normal system brightness.")
        return
    }
    // Switching to normal before changing the full-on preset prevents a
    // flash of maximum brightness when moving between custom levels.
    try intelRestoreSystem(smc)
    let preset: [UInt8] = [level, level]
    do {
        try smc.write("LSLB", bytes: preset)
        guard try smc.read("LSLB") == preset else {
            throw ToolError("Intel LSLB write did not read back correctly")
        }
        try smc.write("LSOO", bytes: [1])
        // Allow fixed-point round-off. The 1...255 range is unverified:
        // do not treat the value as physically calibrated brightness.
        let expected = intelPWMExpected(preset)
        let deadline = Date().addingTimeInterval(2)
        var reached = false
        var observed: [UInt8] = []
        repeat {
            observed = try smc.read("LSPV")
            let off = try smc.read("LSOF")
            if off == [0], observed.count == 2,
               abs(intelUnsigned16(observed) - expected) <= 3 {
                reached = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        guard reached else {
            throw ToolError("Intel brightness level \(level) not verified (LSPV=\(hex(observed)), predicted PWM=\(expected))")
        }
        print("Intel white brightness \(level)/255: LSLB=\(hex(preset)), LSPV=\(hex(observed)).")
        print("Experimental manual level; run --reset to restore normal firmware brightness.")
    } catch {
        writeStderr("WARNING: Intel level change failed; attempting normal-state restoration: \(error)\n")
        do { try intelRestoreSystem(smc) }
        catch { writeStderr("WARNING: automatic Intel recovery failed: \(error). Inspect the LED.\n") }
        throw error
    }
}

func applyIntelSIL(_ state: IntelSILState) throws {
    switch state {
    case .full:
        try intelWriteBrightness(255)
    case .off:
        try intelWriteBrightness(0)
    case .normal:
        let smc = try SMC()
        try checkIntelSIL(smc)
        let _ = try intelStableState(smc)
        try intelRestoreSystem(smc)
        print("Intel LED returned to normal system-controlled brightness (LSLB=FF FF, LSPV=14 11).")
    }
}

func intelSILStatus() throws {
    guard modelID() == "Macmini8,1" else {
        throw ToolError("Intel SIL status is available on Macmini8,1 only")
    }
    let smc = try SMC()
    print("Intel Mac mini 2018 SIL, read-only (actual hardware state must be checked visually):")
    for key in ["LSLN", "LSLB", "LSLF", "LSPV", "LSSV", "LSOF", "LS! ", "LSB!"] {
        let value = (try? smc.read(key)).map(hex) ?? "unavailable"
        print("  \(key): \(value)")
    }
    print("Off, full-white, white blink patterns and selected dimming values verified on one Macmini8,1.")
    print("Custom 0...255 levels are experimental; amber and sleep/wake persistence remain unverified.")
}

// Reject symlinks and unexpected ownership in privileged file destinations.
// Refuse insecure pre-existing paths rather than following them as root.
func validateManagedPath(_ path: String, directory: Bool) throws -> Bool {
    #if os(macOS)
    var attributes = stat()
    if lstat(path, &attributes) != 0 {
        if errno == ENOENT { return false }
        throw ToolError("Cannot inspect \(path): errno \(errno)")
    }
    let kind = attributes.st_mode & mode_t(S_IFMT)
    guard kind == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)) else {
        throw ToolError("Refusing unexpected file type or symlink at \(path)")
    }
    guard attributes.st_uid == 0, (attributes.st_mode & mode_t(0o022)) == 0 else {
        throw ToolError("Refusing non-root-owned or group/world-writable managed path: \(path)")
    }
    return true
    #else
    throw ToolError("Installation requires macOS")
    #endif
}

func setManagedPermissions(_ path: String, directory: Bool, executable: Bool = false) throws {
    let mode = (directory || executable) ? 0o755 : 0o644
    try FileManager.default.setAttributes([
        .ownerAccountID: NSNumber(value: 0),
        .groupOwnerAccountID: NSNumber(value: 0),
        .posixPermissions: NSNumber(value: mode)
    ], ofItemAtPath: path)
}

// The CLI entry is an exact root-owned symlink to our installed executable.
// Reject any unrelated path, symlink, or insecure parent rather than overwriting it.
func validateCLILink() throws -> Bool {
    #if os(macOS)
    var attributes = stat()
    if lstat(cliLink, &attributes) != 0 {
        if errno == ENOENT { return false }
        throw ToolError("Cannot inspect \(cliLink): errno \(errno)")
    }
    guard (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
          attributes.st_uid == 0 else {
        throw ToolError("Refusing unrelated or non-root-owned path at \(cliLink)")
    }
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cliLink)
    guard destination == installedExecutable else {
        throw ToolError("Refusing unrelated symlink at \(cliLink) -> \(destination)")
    }
    return true
    #else
    throw ToolError("Installation requires macOS")
    #endif
}

// Our PATH directory must not be modifiable by non-root users, otherwise
// a malicious replacement of `sudo smcled` could execute arbitrary code.
func validateCLIParents(create: Bool) throws -> Bool {
    let fm = FileManager.default
    let localExists = try validateManagedPath(cliParentDirectory, directory: true)
    if !localExists {
        guard create else { return false }
        try fm.createDirectory(atPath: cliParentDirectory, withIntermediateDirectories: false)
        try setManagedPermissions(cliParentDirectory, directory: true)
    }
    let binExists = try validateManagedPath(cliBinDirectory, directory: true)
    if !binExists {
        guard create else { return false }
        try fm.createDirectory(atPath: cliBinDirectory, withIntermediateDirectories: false)
        try setManagedPermissions(cliBinDirectory, directory: true)
    }
    return true
}

func installCLILink() throws {
    _ = try validateCLIParents(create: true)
    guard !(try validateCLILink()) else { return }
    try FileManager.default.createSymbolicLink(atPath: cliLink, withDestinationPath: installedExecutable)
    guard try validateCLILink() else { throw ToolError("Failed to create managed PATH symlink") }
}

func executableSource() throws -> String {
    // Works when invoked as ./smcled, by absolute path, or through a shell PATH.
    if let url = Bundle.main.executableURL { return url.standardizedFileURL.path }
    throw ToolError("Could not determine this executable's path")
}

func callLaunchctl(_ args: [String], quiet: Bool = false) throws -> Int32 {
    #if os(macOS)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice
    let errorOutput = Pipe()
    proc.standardError = quiet ? FileHandle.nullDevice : errorOutput
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 && !quiet {
        let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ToolError("launchctl \(args.joined(separator: " ")) failed (\(proc.terminationStatus))\(message.isEmpty ? "" : ": " + message)")
    }
    return proc.terminationStatus
    #else
    throw ToolError("LaunchDaemons require macOS")
    #endif
}

func jobIsLoaded() -> Bool {
    (try? callLaunchctl(["print", "system/" + jobLabel], quiet: true)) == 0
}

func createPlistData(automatic: Bool = false, interval: Int = 300, acknowledged: Bool = false) throws -> Data {
    let args = [installedExecutable, "--apply-installed"] + (acknowledged ? ["--accept-untested-model"] : [])
    var settings: [String: Any] = [
        "Label": jobLabel,
        "ProgramArguments": args,
        "RunAtLoad": true,
        "ProcessType": "Background"
    ]
    if automatic { settings["StartInterval"] = interval }
    return try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
}

func writeManagedFile(_ path: String, data: Data, executable: Bool = false) throws {
    let _ = try validateManagedPath(path, directory: false)
    // Atomic replacement avoids leaving partial data if interrupted.
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try setManagedPermissions(path, directory: false, executable: executable)
}

func installBrightness(_ brightness: UInt8, mode: LEDMode = .white, automatic: Bool = false, interval: Int = 300) throws {
    try requireRoot()
    try requireSupportedLEDHost()
    // Validate solar-time source before modifying a previously working installation.
    if automatic { _ = try calculateAutoPlan(at: Date()) }
    // Check access and metadata before touching the installation.
    let smc = try SMC()
    try requireSupportedLEDHost(smc: smc)
    try checkLEDKeys(smc, includeModes: true)

    let fm = FileManager.default
    let exists = try validateManagedPath(installDirectory, directory: true)
    if !exists {
        try fm.createDirectory(atPath: installDirectory, withIntermediateDirectories: false)
        try setManagedPermissions(installDirectory, directory: true)
    }
    // Validate *all* destinations before modifying any of them.
    let _ = try validateManagedPath(installedExecutable, directory: false)
    let _ = try validateManagedPath(brightnessPreference, directory: false)
    let _ = try validateManagedPath(modePreference, directory: false)
    let _ = try validateManagedPath(daemonPlist, directory: false)
    // Validate the PATH destination before stopping any existing service.
    // If /usr/local or /usr/local/bin already exists, it must be root-owned
    // and not writable by other users.
    let _ = try validateCLIParents(create: false)
    let _ = try validateCLILink()

    // A reload is needed if the binary or plist changes.
    if jobIsLoaded() {
        _ = try callLaunchctl(["bootout", "system/" + jobLabel])
    }

    let source = try executableSource()
    if URL(fileURLWithPath: source).resolvingSymlinksInPath().path !=
       URL(fileURLWithPath: installedExecutable).resolvingSymlinksInPath().path {
        let binary = try Data(contentsOf: URL(fileURLWithPath: source))
        try writeManagedFile(installedExecutable, data: binary, executable: true)
    }
    try writeManagedFile(brightnessPreference, data: Data("\(brightness)\n".utf8))
    try writeManagedFile(modePreference, data: Data("\(automatic ? "auto" : mode.rawValue)\n".utf8))
    try writeManagedFile(daemonPlist, data: createPlistData(automatic: automatic, interval: interval, acknowledged: !physicallyTestedDesktops.contains(modelID())))
    try installCLILink()
    // A previously disabled service must be re-enabled explicitly.
    _ = try callLaunchctl(["enable", "system/" + jobLabel])
    _ = try callLaunchctl(["bootstrap", "system", daemonPlist])

    // RunAtLoad already starts the automatic fade. Do NOT duplicate that work
    // from this installer: two concurrent SMC fade loops would interfere.
    if !automatic { try applyKnownLED(smc, mode: mode, brightness: brightness) }
    print(automatic
          ? "Installed \(jobLabel); automatic sunrise/sunset mode (every \(interval) seconds)."
          : "Installed \(jobLabel); saved mode \(mode.rawValue), brightness \(brightness).")
    print("Boot-time job: \(daemonPlist)")
    print("Shell command: \(cliLink) (sudo required to write)")
}

func readInstalledBrightness() throws -> UInt8 {
    guard try validateManagedPath(installDirectory, directory: true),
          try validateManagedPath(brightnessPreference, directory: false) else {
        throw ToolError("No valid installed brightness preference")
    }
    let text = try String(contentsOfFile: brightnessPreference, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try brightnessNumber(text)
}

// v4 installations have no mode file and implicitly mean white.
func readInstalledModeName() throws -> String {
    guard try validateManagedPath(installDirectory, directory: true) else {
        throw ToolError("Installation folder not found")
    }
    guard try validateManagedPath(modePreference, directory: false) else { return LEDMode.white.rawValue }
    let name = try String(contentsOfFile: modePreference, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard name == "auto" || LEDMode(rawValue: name) != nil else {
        throw ToolError("Invalid installed LED mode: \(name)")
    }
    return name
}

func readInstalledMode() throws -> LEDMode {
    let name = try readInstalledModeName()
    guard let mode = LEDMode(rawValue: name) else {
        throw ToolError("Installed mode \(name) is not a fixed LED mode")
    }
    return mode
}

func preferredBrightnessOrDefault() throws -> UInt8 {
    if try validateManagedPath(installDirectory, directory: true),
       try validateManagedPath(brightnessPreference, directory: false) {
        return try readInstalledBrightness()
    }
    return 255
}

func applyInstalledBrightness() throws {
    try requireRoot()
    let brightness = try readInstalledBrightness()
    let modeName = try readInstalledModeName()
    // The SMC may not be ready at the first instant launchd loads us.
    // This is a bounded one-shot startup job, not a resident process.
    if modeName != "auto" { Thread.sleep(forTimeInterval: 4) }
    var lastError: Error?
    for attempt in 1...15 {
        do {
            let smc = try SMC()
            try requireSupportedLEDHost(smc: smc)
            if modeName == "auto" { try applyAutomaticLED(smc) }
            else { try applyKnownLED(smc, mode: LEDMode(rawValue: modeName)!, brightness: brightness) }
            return
        } catch {
            lastError = error
            if attempt < 15 { Thread.sleep(forTimeInterval: 2) }
        }
    }
    throw ToolError("Could not apply saved brightness after 15 attempts: \(String(describing: lastError))")
}

func uninstallBrightness() throws {
    try requireRoot()
    let fm = FileManager.default
    // Validate everything before unloading/removing any components.
    let hasDirectory = try validateManagedPath(installDirectory, directory: true)
    if hasDirectory {
        let _ = try validateManagedPath(installedExecutable, directory: false)
        let _ = try validateManagedPath(brightnessPreference, directory: false)
        let _ = try validateManagedPath(modePreference, directory: false)
        // Never recursively remove an unexpected file/folder.
        let known = Set(["smcled", "brightness", "mode"])
        let contents = try fm.contentsOfDirectory(atPath: installDirectory)
        guard Set(contents).isSubset(of: known) else {
            throw ToolError("Refusing to delete \(installDirectory): unexpected contents \(contents)")
        }
    }
    let _ = try validateManagedPath(daemonPlist, directory: false)
    let hasCLILink = try validateCLILink()
    if hasCLILink { _ = try validateCLIParents(create: false) }

    if jobIsLoaded() {
        _ = try callLaunchctl(["bootout", "system/" + jobLabel])
    }
    // Restore the factory brightness where possible before deleting files.
    do {
        try setKnownLEDBrightness(255)
        print("Restored normal LED brightness (255).")
    } catch {
        writeStderr("WARNING: Could not restore LED brightness: \(error)\n")
    }
    if hasCLILink { try fm.removeItem(atPath: cliLink) }
    if fm.fileExists(atPath: daemonPlist) { try fm.removeItem(atPath: daemonPlist) }
    if hasDirectory { try fm.removeItem(atPath: installDirectory) }
    print("Uninstalled \(jobLabel), preferences, executable, and managed PATH link.")
}

func installationStatus() throws {
    let dir = try validateManagedPath(installDirectory, directory: true)
    let config = try validateManagedPath(brightnessPreference, directory: false)
    let binary = try validateManagedPath(installedExecutable, directory: false)
    let plist = try validateManagedPath(daemonPlist, directory: false)
    print("Install: \(dir && binary && config && plist ? "complete" : "incomplete / not installed")")
    print("launchd loaded: \(jobIsLoaded() ? "yes" : "no")")
    print("CLI PATH link: \((try validateCLILink()) ? cliLink : "not installed")")
    if config {
        let installedMode = try readInstalledModeName()
        print("Configured mode: \(installedMode)")
        if installedMode == "auto" {
            if plist {
                let data = try Data(contentsOf: URL(fileURLWithPath: daemonPlist))
                let properties = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                if let settings = properties as? [String: Any],
                   let seconds = settings["StartInterval"] as? Int, seconds > 0 {
                    print("Auto check interval: \(seconds) seconds")
                } else {
                    print("Auto check interval: unknown (missing StartInterval)")
                }
            } else {
                print("Auto check interval: unavailable (LaunchDaemon missing)")
            }
        }
        else { print("Configured brightness: \(try readInstalledBrightness())") }
    }
    if supportedAppleSiliconDesktops.contains(modelID()) {
        let smc = try SMC()
        print("Current LSLN raw: \(hex(try smc.read("LSLN")))")
        print("Current LSCS (channel): \(hex(try smc.read("LSCS")))")
    }
}

// Experimental: bounded LED-channel probe, based on the actual j274 SMC firmware.
// LSSB mode 4 selects a channel-1 preset using a constant 0xFFFF output
// source (firmware j274 SMC preset at 0x5C9A8), matching the constant-on
// channel-0 preset at 0x5C918 apart from the channel selector.
// Mode 4 was physically confirmed as fixed amber; 8 and 9 as different flash patterns.
// LSRB invokes the firmware's saved-state restore.
 // This is a short experiment and is deliberately not persistent.
func testAmberChannel(mode: UInt8) throws {
    guard mode == 4 || mode == 8 || mode == 9 else { throw ToolError("Allowed experimental modes: 4, 8 or 9") }
    try requireRoot()
    try requireM1Mini()
    let smc = try SMC()
    let checks: [(String, UInt32, String, Bool)] = [
        ("LSSB", 2, "hex_", true),
        ("LSRB", 1, "flag", true),
        ("LSCS", 1, "ui8 ", false),
        ("LS0P", 2, "ui16", false),
        ("LS1P", 2, "ui16", false),
        ("LSLN", 2, "ui16", false),
    ]
    for (key, size, type, requiresWrite) in checks {
        let info = try smc.info(key)
        guard info.size == size, info.type == type,
              requiresWrite ? info.writable : info.readable else {
            throw ToolError("Firmware key \(key) metadata does not match the M1 j274 profile; refusing test")
        }
    }
    let previousBrightness = try smc.read("LSLN")
    let originalChannel = try smc.read("LSCS")
    guard originalChannel == [0x00] else {
        throw ToolError("Expected normal white LED channel (LSCS=00); got \(hex(originalChannel)). Refusing test.")
    }
    print("Current LED channel selection LSCS: \(hex(originalChannel))")
    print("Current LED brightness LSLN: \(hex(previousBrightness))")
    print("Sending LSSB predefined mode \(mode) (\(hex([mode, 0]))); 3-second visual test...")
    // Assume a write can have taken effect even if its acknowledgement fails.
    defer {
        print("Restoring saved LED state via LSRB...")
        do { try restoreWhiteChannel(smc) }
        catch { writeStderr("WARNING: LSRB/white restore failed: \(error)\n") }
        do { try smc.write("LSLN", bytes: previousBrightness) }
        catch { writeStderr("WARNING: brightness restore failed: \(error)\n") }
        do {
            print("Final LSCS: \(hex(try smc.read("LSCS"))), LS1P: \(hex(try smc.read("LS1P"))), LSLN: \(hex(try smc.read("LSLN")))")
        } catch { writeStderr("Could not read restored state: \(error)\n") }
    }
    try smc.write("LSSB", bytes: [mode, 0x00])
    for index in 1...6 {
        Thread.sleep(forTimeInterval: 0.5)
        print("+\(Double(index) * 0.5)s  LSCS=\(hex(try smc.read("LSCS")))  LS0P=\(hex(try smc.read("LS0P")))  LS1P=\(hex(try smc.read("LS1P")))")
    }
}

// Explicitly experimental test: checks whether changing the normal-white LSLN
// register affects the already active amber channel. Does not claim that it does.
// Starts in normal white mode, applies fixed amber, samples its PWM, then writes
// one LSLN value and observes amber PWM. Restores the original state on return.
// Opt-in candidate test: the Mac Studio's white LED brightness is physically
// verified, but LSSB/LSRB channel behavior has not yet been confirmed.
// This test is intentionally restricted to Mac16,9 and never installs a job.
func testStudioAmberCandidate() throws {
    try requireRoot()
    guard modelID() == "Mac16,9" else {
        throw ToolError("This diagnostic is restricted to the Mac16,9 Mac Studio")
    }
    guard !jobIsLoaded() else {
        throw ToolError("Stop the smcled LaunchDaemon before experimenting with LED modes")
    }
    let smc = try SMC()
    guard signatureMatches(readCompatibilityKeys(smc), specs: fullSignature) else {
        throw ToolError("Required LED key metadata differs from the tested SMC profile")
    }
    let initial = try readLEDOutput(smc)
    guard initial.selection == [0], initial.amberPWM == [0, 0],
          initial.whiteActive, initial.brightness.count == 2,
          initial.brightness[0] == initial.brightness[1] else {
        throw ToolError("Expected normal white LED with symmetric brightness; no writes attempted")
    }
    let cancellation = DiagnosticCancellation()
    print("Mac16,9 amber candidate test (not previously hardware verified).")
    print("Initial LSCS=\(hex(initial.selection)) LS0P=\(hex(initial.whitePWM))" +
          " LS1P=\(hex(initial.amberPWM)) LSLN=\(hex(initial.brightness))")
    print("Will dim to zero, apply LSSB mode 4, briefly show candidate amber at 100," +
          " then restore normal white. Observe the physical LED.")
    // Arm restoration before any writes. If a write fails or a handled signal is
    // received, attempt the independent restoration steps anyway. SIGKILL,
    // process crashes, and power failures still cannot be recovered in-process.
    defer {
        print("Restoring original white state...")
        do { try smc.write("LSLN", bytes: [0, 0]) }
        catch { writeStderr("WARNING: could not blank LED for restoration: \(error)\n") }
        do { try restoreWhiteChannel(smc) }
        catch { writeStderr("WARNING: white mode restore failed: \(error)\n") }
        do { try smc.write("LSLN", bytes: initial.brightness) }
        catch { writeStderr("WARNING: original brightness restore failed: \(error)\n") }
        do {
            let restored = try readLEDOutput(smc)
            print("Restored LSCS=\(hex(restored.selection)) LS0P=\(hex(restored.whitePWM))" +
                  " LS1P=\(hex(restored.amberPWM)) LSLN=\(hex(restored.brightness))")
            if restored.selection != initial.selection ||
               restored.amberPWM != [0, 0] ||
               restored.brightness != initial.brightness {
                writeStderr("WARNING: post-test LED state differs from initial state\n")
            }
        } catch { writeStderr("WARNING: restoration readback failed: \(error)\n") }
    }
    try cancellation.check()
    try smc.write("LSLN", bytes: [0, 0])
    try cancellation.pause(0.35)
    try smc.write("LSSB", bytes: [4, 0])
    try cancellation.pause(0.4)
    let selected = try readLEDOutput(smc)
    print("Mode 4 LSCS=\(hex(selected.selection)) LS0P=\(hex(selected.whitePWM))" +
          " LS1P=\(hex(selected.amberPWM)) LSLN=\(hex(selected.brightness))")
    guard selected.selection == [1], selected.whitePWM == [0, 0] else {
        print("SMC channel response differs from M1. Stopping before illuminating amber.")
        return
    }
    try cancellation.check()
    try smc.write("LSLN", bytes: [100, 100])
    try cancellation.pause(1.5)
    let amber = try readLEDOutput(smc)
    print("Candidate amber LSCS=\(hex(amber.selection))" +
          " LS0P=\(hex(amber.whitePWM)) LS1P=\(hex(amber.amberPWM))" +
          " LSLN=\(hex(amber.brightness))")
    if amber.selection == [1] && amber.whitePWM == [0, 0] &&
       amber.amberActive && amber.brightness == [100, 100] {
        print("SMC telemetry matches amber mode. Physical color must be confirmed visually.")
    } else {
        print("SMC telemetry does not confirm the M1-style amber mode.")
    }
    try cancellation.check()
}

func testAmberBrightness(_ candidate: UInt8) throws {
    try requireRoot()
    try requireM1Mini()
    let smc = try SMC()
    try checkLEDKeys(smc, includeModes: true)
    let saved = try smc.read("LSLN")
    let channel = try smc.read("LSCS")
    let originalAmber = try smc.read("LS1P")
    guard channel == [0] && originalAmber == [0, 0] else {
        throw ToolError("Start in normal white mode before brightness test (sudo smcled --white)")
    }
    print("Testing whether LSLN affects STEADY AMBER. Saved LSLN=\(hex(saved)).")
    print("The test will run briefly then attempt automatic restoration.")
    defer {
        print("Restoring normal white LED via LSRB and original LSLN...")
        do { try restoreWhiteChannel(smc) }
        catch { writeStderr("WARNING: white channel restore failed: \(error)\n") }
        do { try smc.write("LSLN", bytes: saved) }
        catch { writeStderr("WARNING: brightness restore failed: \(error)\n") }
        if let c = try? smc.read("LSCS"), let p = try? smc.read("LS1P"), let b = try? smc.read("LSLN") {
            print("Final LSCS=\(hex(c)), LS1P=\(hex(p)), LSLN=\(hex(b))")
        }
    }
    // Mode 4 is the hardware-confirmed fixed amber preset.
    try smc.write("LSSB", bytes: [4, 0])
    Thread.sleep(forTimeInterval: 1.2)
    let before = try smc.read("LS1P")
    let beforeChannel = try smc.read("LSCS")
    print("Before change: LSCS=\(hex(beforeChannel)), LS1P=\(hex(before)).")
    guard beforeChannel == [1], before != [0, 0] else {
        throw ToolError("Steady amber did not activate as expected; canceling test")
    }
    try smc.write("LSLN", bytes: [candidate, candidate])
    for index in 1...5 {
        Thread.sleep(forTimeInterval: 0.5)
        let currentChannel = try smc.read("LSCS")
        let currentAmber = try smc.read("LS1P")
        print("+\(Double(index) * 0.5)s  LSCS=\(hex(currentChannel)), LS1P=\(hex(currentAmber))")
    }
    print("Compare LS1P against baseline \(hex(before)) and observe the physical LED.")
    print("No persistent setting was modified. Steady amber dimming has also been visually confirmed on M1 hardware.")
}

// Diagnostic only: sample both PWM outputs while switching between the two
// hardware-confirmed steady-light modes. The *read-only* LS0P/LS1P keys report
// output telemetry; they are not controls. A nonzero reading on both keys is
// interesting evidence, but cannot by itself establish visually mixed light.
// This test deliberately does NOT write unexplored channel/LED configuration keys.
struct LEDOutputSample {
    let selection: [UInt8]
    let whitePWM: [UInt8]
    let amberPWM: [UInt8]
    let brightness: [UInt8]

    var whiteActive: Bool { whitePWM.contains { $0 != 0 } }
    var amberActive: Bool { amberPWM.contains { $0 != 0 } }
    var bothActive: Bool { whiteActive && amberActive }
}

func readLEDOutput(_ smc: SMC) throws -> LEDOutputSample {
    LEDOutputSample(selection: try smc.read("LSCS"),
                    whitePWM: try smc.read("LS0P"),
                    amberPWM: try smc.read("LS1P"),
                    brightness: try smc.read("LSLN"))
}

// Dispatch signal sources run on a normal queue, not in an async signal
// handler. An interruption is observed promptly by the test loop, which then
// unwinds normally through its defer-based hardware restoration.
// SIGKILL, a crash or a sudden power loss cannot be handled in software.
final class DiagnosticCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedSignal: Int32?
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        #if os(macOS)
        let queue = DispatchQueue(label: "smcled.dual-channel.signals")
        for number in [SIGINT, SIGTERM] {
            // DispatchSourceSignal requires the traditional disposition to
            // be ignored so that default termination does not bypass cleanup.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.record(number)
            }
            source.resume()
            signalSources.append(source)
        }
        #endif
    }

    private func record(_ number: Int32) {
        lock.lock()
        receivedSignal = number
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let pending = receivedSignal
        lock.unlock()
        if let pending {
            throw ToolError("Diagnostic interrupted by signal \(pending); restoring normal white LED")
        }
    }

    func pause(_ seconds: TimeInterval) throws {
        let finish = Date().addingTimeInterval(seconds)
        repeat {
            try check()
            let remaining = finish.timeIntervalSinceNow
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(remaining, 0.05))
        } while true
        try check()
    }
}

// An opt-in, reversible physical test for machines not yet verified.
// Does NOT select channels or send behavior presets: only a temporary LSLN
// change is attempted, then the exact original bytes are restored.
// The user must visually confirm whether the power LED actually dimmed.
// Macmini8,1 research-only probe. Its LSLN=2F FF baseline is NOT the
// symmetric brightness encoding confirmed on Apple Silicon. This diagnostic
// changes only the second byte, for two seconds, restoring both original bytes.
// It does not grant ordinary LED operations on this Intel model.
// Intel 2018 exploratory diagnostics. No SMC key other than LSLN is ever
// written. The observed baseline 2F FF is a hard prerequisite, NOT a known
// brightness encoding. First-byte writes are unverified and potentially risky.
enum IntelLSLNByte: String {
    case first
    case second
}

struct IntelLSLNExperiment {
    let byte: IntelLSLNByte
    let value: UInt8
    let label: String
}

func intelProposedBytes(_ baseline: [UInt8], experiment: IntelLSLNExperiment) -> [UInt8] {
    var proposed = baseline
    switch experiment.byte {
    case .first: proposed[0] = experiment.value
    case .second: proposed[1] = experiment.value
    }
    return proposed
}

// Read-only before/after key inventory. Missing keys are normal and are
// reported explicitly; write-only keys are never read.
func intelLEDReadout(_ smc: SMC, heading: String) {
    print(heading)
    for key in ["LSLN", "LSLB", "LSLF", "LS0C", "LS0P", "LS0S",
                "LS1C", "LS1P", "LS1S", "LSCS", "LSOF", "LSSE"] {
        do {
            let info = try smc.info(key)
            guard info.readable, info.size > 0, info.size <= 32 else {
                print("  \(key): present, not readable")
                continue
            }
            let bytes = try smc.read(key)
            print("  \(key): \(hex(bytes))")
        } catch {
            print("  \(key): unavailable")
        }
    }
}

// Return a vetted experimental context. The Intel SMC uses different data
// than the known Apple Silicon profile; we do not reuse its color controls.
func intelTestContext() throws -> (SMC, [UInt8]) {
    try requireRoot()
    guard modelID() == "Macmini8,1" else {
        throw ToolError("Intel diagnostics are restricted to the Macmini8,1")
    }
    guard !jobIsLoaded() else {
        throw ToolError("Stop the smcled LaunchDaemon before Intel experiments")
    }
    let smc = try SMC()
    let info = try smc.info("LSLN")
    guard info.size == 2, info.type == "ui16", info.readable, info.writable else {
        throw ToolError("Unexpected Intel LSLN metadata; no write attempted")
    }
    let original = try smc.read("LSLN")
    guard original == [0x2F, 0xFF] else {
        throw ToolError("Expected observed Intel baseline 2F FF; got \(hex(original)). No write attempted")
    }
    return (smc, original)
}

// This function is shared by the individual test and test suite. Restoration
// is performed before returning; any failed readback aborts the sequence.
func runIntelLSLNStep(_ smc: SMC, original: [UInt8],
                      experiment: IntelLSLNExperiment,
                      cancellation: DiagnosticCancellation) throws {
    guard original == [0x2F, 0xFF] else { throw ToolError("Unexpected Intel baseline") }
    try cancellation.check()
    let before = try smc.read("LSLN")
    guard before == original else {
        throw ToolError("Intel LSLN changed unexpectedly to \(hex(before)); aborting")
    }
    if experiment.byte == .first && !(0x20...0x40).contains(experiment.value) {
        throw ToolError("Experimental first-byte values limited to 32...64 for Macmini8,1")
    }
    let requested = intelProposedBytes(original, experiment: experiment)
    guard requested != original else { throw ToolError("Test value is identical to original") }
    print("TEST \(experiment.label): \(hex(original)) -> \(hex(requested)) for 2 seconds")
    // Arm restoration before the first write, including if SMC rejects it.
    // A crash, SIGKILL, or sudden power loss cannot trigger this cleanup.
    var restorationError: Error?
    do {
        try smc.write("LSLN", bytes: requested)
        let observed = try smc.read("LSLN")
        print("  SMC readback: \(hex(observed))")
        try cancellation.pause(2.0)
    } catch {
        restorationError = error
    }
    // Always restore, independently of the preceding test result.
    do {
        try smc.write("LSLN", bytes: original)
        let restored = try smc.read("LSLN")
        print("  Restored LSLN: \(hex(restored))")
        guard restored == original else {
            throw ToolError("Intel LSLN restore mismatch; expected \(hex(original)), got \(hex(restored)). STOP")
        }
    } catch {
        writeStderr("WARNING: Intel LSLN restoration failed: \(error)\n")
        throw error
    }
    if let restorationError { throw restorationError }
    print("  Visual result: compare LED brightness manually; no automatic confirmation.")
}

func runIntelLSLNExperiments(_ experiments: [IntelLSLNExperiment]) throws {
    let (smc, original) = try intelTestContext()
    let cancellation = DiagnosticCancellation()
    print("EXPERIMENTAL Macmini8,1 LSLN tests. Original register \(hex(original)).")
    print("The byte meanings are UNKNOWN. First-byte changes are UNTESTED.")
    print("Only LSLN is written, never LSSB, LSRB, or channel configuration keys.")
    print("If an interrupted test leaves the LED changed, stop and investigate.")
    intelLEDReadout(smc, heading: "Before tests (read only):")
    // Final fallback even if a stage fails. This must not replace the
    // per-stage restoration/verification above.
    defer {
        do {
            let current = try smc.read("LSLN")
            if current != original {
                try smc.write("LSLN", bytes: original)
                print("Final fallback restore: \(hex(try smc.read("LSLN")))")
            }
        } catch {
            writeStderr("WARNING: Final Intel LSLN restoration failed: \(error)\n")
        }
    }
    for (index, experiment) in experiments.enumerated() {
        print("Step \(index + 1)/\(experiments.count)")
        try runIntelLSLNStep(smc, original: original,
                             experiment: experiment, cancellation: cancellation)
        intelLEDReadout(smc, heading: "After step \(index + 1) (read only):")
        if index + 1 < experiments.count { try cancellation.pause(0.75) }
    }
    print("Intel diagnostics complete; no persistent setting was installed.")
}

func intelReadOnlyDiagnostics() throws {
    guard modelID() == "Macmini8,1" else {
        throw ToolError("Intel diagnostics are restricted to Macmini8,1")
    }
    let smc = try SMC()
    intelLEDReadout(smc, heading: "Macmini8,1 LED-related SMC snapshot (read only):")
}

func intelSuite() throws {
    // Conservative first-byte variations around the observed value 0x2F.
    // The second-byte variation is included as a reproducibility control.
    try runIntelLSLNExperiments([
        IntelLSLNExperiment(byte: .first, value: 0x20, label: "first byte 2F -> 20"),
        IntelLSLNExperiment(byte: .first, value: 0x40, label: "first byte 2F -> 40"),
        IntelLSLNExperiment(byte: .second, value: 0x64, label: "second byte FF -> 64 (prior no visible effect)")
    ])
}

// Legacy command retained, using the same step engine as all new tests.
func testIntelBrightnessCandidate(_ candidate: UInt8) throws {
    try runIntelLSLNExperiments([
        IntelLSLNExperiment(byte: .second, value: candidate, label: "second byte")
    ])
}

func testBrightnessCandidate(_ candidate: UInt8) throws {
    try requireRoot()
    let smc = try SMC()
    let keys = readCompatibilityKeys(smc)
    let level = compatibilityLevel(modelID(), keys)
    guard level != .unavailable else {
        throw ToolError("LSLN metadata is not compatible; refusing hardware test")
    }
    guard !jobIsLoaded() else {
        throw ToolError("Stop the smcled LaunchDaemon before a temporary hardware probe")
    }
    let original = try smc.read("LSLN")
    guard original.count == 2, original[0] == original[1] else {
        throw ToolError("LSLN bytes are asymmetric (\(hex(original))); refusing writes. Use --sample-brightness for a read-only investigation")
    }
    let requested = [candidate, candidate]
    guard original != requested else {
        throw ToolError("Test brightness equals current value; choose a different level")
    }
    // Do not test in a non-white preset if channel telemetry is present.
    if level == .verified || level == .fullCandidate {
        guard try smc.read("LSCS") == [0], try smc.read("LS1P") == [0, 0] else {
            throw ToolError("Start from normal white mode for a reversible test")
        }
    }
    let cancellation = DiagnosticCancellation()
    print("Temporary LSLN test on \(modelID()), brightness \(original[0]) -> \(candidate).")
    print("Observe the physical LED. Metadata/readback alone cannot verify support.")
    // Always arm cleanup before the first write. Signals can interrupt the pause;
    // sudden power loss or SIGKILL cannot be recovered automatically.
    defer {
        do {
            try smc.write("LSLN", bytes: original)
            let restored = try smc.read("LSLN")
            print("Restored LSLN=\(hex(restored))" + (restored == original ? "" : " [WARNING: mismatch]"))
        } catch { writeStderr("WARNING: failed to restore LSLN: \(error)\n") }
    }
    try cancellation.check()
    try smc.write("LSLN", bytes: requested)
    let observed = try smc.read("LSLN")
    print("Test LSLN readback: \(hex(observed))")
    try cancellation.pause(2.0)
    if observed != requested {
        print("SMC did not echo the requested brightness; hardware support is unconfirmed.")
    } else {
        print("SMC accepted the change; physical LED behavior still needs visual confirmation.")
    }
}

func collectLEDOutput(_ smc: SMC,
                      stage: String,
                      samples count: Int,
                      spacing: TimeInterval,
                      cancellation: DiagnosticCancellation) throws -> [LEDOutputSample] {
    print("\n\(stage)")
    var samples: [LEDOutputSample] = []
    for index in 0..<count {
        if index > 0 { try cancellation.pause(spacing) }
        try cancellation.check()
        let current = try readLEDOutput(smc)
        samples.append(current)
        print(String(format: "  +%.2fs", Double(index) * spacing) +
              "  LSCS=\(hex(current.selection))" +
              "  LS0P=\(hex(current.whitePWM))" +
              "  LS1P=\(hex(current.amberPWM))" +
              "  LSLN=\(hex(current.brightness))" +
              (current.bothActive ? "  [BOTH NONZERO]" : ""))
    }
    return samples
}

// Tests whether the verified mode-switch protocol preserves the original
// channel or briefly drives both channels during a transition. It cannot test
// independent control of both LEDs: there is no verified channel-specific
// brightness command, and LS0P/LS1P are read-only telemetry.
func testDualChannel() throws {
    try requireRoot()
    try requireM1Mini()
    let smc = try SMC()
    try checkLEDKeys(smc, includeModes: true)

    let initial = try readLEDOutput(smc)
    // An active amber/flashing preset is not recoverable from LSCS alone.
    // Require normal white so LSRB + original brightness restores the entry state.
    guard initial.selection == [0], initial.amberPWM == [0, 0] else {
        throw ToolError("Begin in normal white mode (sudo ./smcled --white); " +
                        "LSCS=\(hex(initial.selection)), LS1P=\(hex(initial.amberPWM))")
    }

    let originalBrightness = initial.brightness
    print("Dual-channel diagnostic: verified SMC operations only, no persistence.")
    print("Original: LSCS=\(hex(initial.selection)) " +
          "LS0P=\(hex(initial.whitePWM)) " +
          "LS1P=\(hex(initial.amberPWM)) " +
          "LSLN=\(hex(originalBrightness))")
    print("Testing white 100 -> amber 100 -> white 100.")
    print("Observe whether both colors appear simultaneously at any point.")

    let cancellation = DiagnosticCancellation()
    // Install restoration BEFORE the first write. This is best effort only.
    defer {
        print("\nRestoring normal white and original brightness...")
        do { try restoreWhiteChannel(smc) }
        catch { writeStderr("WARNING: could not restore white channel: \(error)\n") }
        do { try smc.write("LSLN", bytes: originalBrightness) }
        catch { writeStderr("WARNING: could not restore original brightness: \(error)\n") }
        do {
            let final = try readLEDOutput(smc)
            print("Restored: LSCS=\(hex(final.selection)) " +
                  "LS0P=\(hex(final.whitePWM)) " +
                  "LS1P=\(hex(final.amberPWM)) " +
                  "LSLN=\(hex(final.brightness))")
            if final.selection != [0] || final.amberActive || final.brightness != originalBrightness {
                writeStderr("WARNING: final readback differs from the expected restored state\n")
            }
        } catch { writeStderr("WARNING: could not verify restoration: \(error)\n") }
    }

    try cancellation.check()
    try smc.write("LSLN", bytes: [100, 100])
    let white = try collectLEDOutput(smc, stage: "Steady white at 100", samples: 6,
                                     spacing: 0.20, cancellation: cancellation)
    try cancellation.check()
    // LSSB mode 4 is confirmed to produce constant amber. Crucially, we do
    // not issue LSRB or set brightness to zero before this transition: the
    // test observes whether the firmware retains any white PWM output.
    try smc.write("LSSB", bytes: [4, 0])
    let amber = try collectLEDOutput(smc, stage: "Transition to steady amber at 100", samples: 16,
                                     spacing: 0.20, cancellation: cancellation)

    try cancellation.check()
    try restoreWhiteChannel(smc)
    let backToWhite = try collectLEDOutput(smc, stage: "Return to normal white at 100", samples: 6,
                                           spacing: 0.20, cancellation: cancellation)

    let all = white + amber + backToWhite
    let bothCount = all.filter { $0.bothActive }.count
    let steadyAmber = Array(amber.suffix(5))
    let amberExclusive = steadyAmber.allSatisfy {
        $0.selection == [1] && !$0.whiteActive && $0.amberActive
    }
    let steadyWhite = Array(backToWhite.suffix(3))
    let whiteExclusive = steadyWhite.allSatisfy {
        $0.selection == [0] && $0.whiteActive && !$0.amberActive
    }

    print("\nRESULT")
    if bothCount > 0 {
        print("Found \(bothCount) sample(s) with nonzero PWM on both channels.")
        print("This may be a transient; it does NOT prove visible mixing or independent dimming.")
    } else if amberExclusive && whiteExclusive {
        print("The known steady presets use mutually exclusive PWM channels.")
        print("No simultaneous output was observed at this sampling resolution.")
    } else {
        print("Inconclusive: LED telemetry did not settle into the expected known modes.")
    }
    print("Independent two-channel brightness control remains unverified.")
    print("No writes to LS0P, LS1P, LS0C, LS1C, LS0S or LS1S were attempted.")
    print("Please report whether the physical LED showed any white/amber blend.")
}

// MARK: - Sunrise/sunset automation
// The system-selected city is an undocumented but locally readable macOS
// installation setting. It provides coordinates without CoreLocation/TCC.
private let globalTimeZonePreferences = "/Library/Preferences/.GlobalPreferences.plist"

struct SolarLocation {
    let latitude: Double
    let longitude: Double
    let timeZone: TimeZone
    let label: String

    init(latitude: Double, longitude: Double, timeZone: TimeZone, label: String) throws {
        guard latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
              && (-180...180).contains(longitude) else {
            throw ToolError("Invalid latitude/longitude in system city preference")
        }
        self.latitude = latitude
        self.longitude = longitude
        self.timeZone = timeZone
        self.label = label
    }
}

func systemSelectedCity() -> SolarLocation? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: globalTimeZonePreferences)),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let parts = dict["com.apple.TimeZonePref.Last_Selected_City"] as? [Any],
          parts.count >= 7 else { return nil }
    func double(_ value: Any) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
    guard let latitude = double(parts[0]), let longitude = double(parts[1]),
          let identifier = parts[3] as? String,
          let zone = TimeZone(identifier: identifier),
          let city = parts[5] as? String,
          let country = parts[6] as? String else { return nil }
    return try? SolarLocation(latitude: latitude, longitude: longitude,
                               timeZone: zone, label: "\(city), \(country) (system city)")
}

struct SolarDay {
    let sunrise: Date
    let sunset: Date
}

func configuredCalendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

// NOAA fractional-year approximation, horizon zenith 90.833 degrees.
// Atmospheric conditions/horizon can shift the actual visible sunrise/set.
func solarDay(for localDate: Date, location: SolarLocation) throws -> SolarDay {
    let cal = configuredCalendar(location.timeZone)
    guard let day = cal.ordinality(of: .day, in: .year, for: localDate),
          let days = cal.range(of: .day, in: .year, for: localDate)?.count else {
        throw ToolError("Could not determine the local calendar day")
    }
    let angle = 2.0 * Double.pi / Double(days) * Double(day - 1)
    let equation = 229.18 * (0.000075 + 0.001868*cos(angle)
                            - 0.032077*sin(angle) - 0.014615*cos(2*angle)
                            - 0.040849*sin(2*angle))
    let declination = 0.006918 - 0.399912*cos(angle)
                    + 0.070257*sin(angle) - 0.006758*cos(2*angle)
                    + 0.000907*sin(2*angle) - 0.002697*cos(3*angle)
                    + 0.00148*sin(3*angle)
    let lat = location.latitude * .pi / 180.0
    let zenith = 90.833 * .pi / 180.0
    let numerator = cos(zenith) - sin(lat) * sin(declination)
    let denominator = cos(lat) * cos(declination)
    let cosine = numerator / denominator
    guard cosine.isFinite && (-1.0...1.0).contains(cosine) else {
        throw ToolError("No sunrise/sunset on this date at the configured latitude")
    }
    let hourAngle = acos(cosine) * 180.0 / .pi
    let dateParts = cal.dateComponents([.year, .month, .day], from: localDate)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let midnightUTC = utc.date(from: dateParts) else {
        throw ToolError("Could not construct UTC date for solar calculation")
    }
    let noonUTCMinutes = 720.0 - 4.0*location.longitude - equation
    return SolarDay(sunrise: midnightUTC.addingTimeInterval((noonUTCMinutes - 4*hourAngle)*60.0),
                    sunset: midnightUTC.addingTimeInterval((noonUTCMinutes + 4*hourAngle)*60.0))
}

// Fallback to the solar events in the diagnostic's *Sunset/Sunrise* section;
// do not mistakenly interpret Night Shift's fixed 07:00/22:00 schedule as
// actual solar events. This private executable may change without notice.
func coreBrightnessSolarDays() throws -> (TimeZone, String, [SolarDay]) {
    #if os(macOS)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/libexec/corebrightnessdiag")
    proc.arguments = ["nightshift-internal"]
    let output = Pipe()
    proc.standardOutput = output
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    let group = DispatchGroup()
    group.enter()
    proc.terminationHandler = { _ in group.leave() }
    if group.wait(timeout: .now() + 5) == .timedOut {
        proc.terminate()
        throw ToolError("CoreBrightness diagnostic timed out")
    }
    guard proc.terminationStatus == 0 else {
        throw ToolError("CoreBrightness diagnostic returned status \(proc.terminationStatus)")
    }
    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let pattern = #"(?m)\b(previousSunrise|sunrise|nextSunrise|previousSunset|sunset|nextSunset)\s*=\s*"([^"]+)""#
    let matcher = try NSRegularExpression(pattern: pattern)
    let ns = result as NSString
    let dateFormat = DateFormatter()
    dateFormat.locale = Locale(identifier: "en_US_POSIX")
    dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let zone = TimeZone.current
    let cal = configuredCalendar(zone)
    var events: [String: Date] = [:]
    for match in matcher.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
        let key = ns.substring(with: match.range(at: 1))
        let value = ns.substring(with: match.range(at: 2))
        if let date = dateFormat.date(from: value) { events[key] = date }
    }
    var sunrises: [Date: Date] = [:]
    var sunsets: [Date: Date] = [:]
    for (key, date) in events {
        let day = cal.startOfDay(for: date)
        if key.lowercased().contains("sunrise") { sunrises[day] = date }
        else { sunsets[day] = date }
    }
    let days = sunrises.keys.sorted().compactMap { day -> SolarDay? in
        guard let rise = sunrises[day], let set = sunsets[day], rise < set else { return nil }
        return SolarDay(sunrise: rise, sunset: set)
    }
    guard !days.isEmpty else {
        throw ToolError("CoreBrightness returned no matching sunrise/sunset dates; refusing to use fixed Night Shift hours")
    }
    return (zone, "CoreBrightness diagnostic fallback", days)
    #else
    throw ToolError("CoreBrightness diagnostic is available only on macOS")
    #endif
}

struct LEDTransition {
    let date: Date
    let mode: LEDMode
    let brightness: UInt8
    let description: String
}

struct AutomaticPlan {
    let source: String
    let zone: TimeZone
    let days: [SolarDay]
    let events: [LEDTransition]
    let target: LEDTransition
    let next: LEDTransition?
}

func calculateAutoPlan(at now: Date, location explicit: SolarLocation? = nil) throws -> AutomaticPlan {
    let source: String
    let zone: TimeZone
    let days: [SolarDay]
    if let location = explicit ?? systemSelectedCity() {
        source = location.label
        zone = location.timeZone
        let calendar = configuredCalendar(zone)
        let today = calendar.startOfDay(for: now)
        // Include adjacent days: sunset + 3h can cross midnight, and
        // an early-morning poll may still be in yesterday's amber mode.
        days = try (-2...2).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else {
                throw ToolError("Could not add local calendar day")
            }
            return try solarDay(for: date, location: location)
        }
    } else {
        let fallback = try coreBrightnessSolarDays()
        zone = fallback.0
        source = fallback.1
        days = fallback.2
    }
    let calendar = configuredCalendar(zone)
    var events: [LEDTransition] = []
    for day in days {
        let sunsetHour = calendar.component(.hour, from: day.sunset)
        let late = sunsetHour >= 21
        events += [
            LEDTransition(date: day.sunrise.addingTimeInterval(-3600), mode: .amber,
                          brightness: 100, description: "Sunrise - 1h"),
            LEDTransition(date: day.sunrise, mode: .white,
                          brightness: 33, description: "Sunrise"),
            LEDTransition(date: day.sunrise.addingTimeInterval(3600), mode: .white,
                          brightness: 255, description: "Sunrise + 1h"),
            LEDTransition(date: day.sunset, mode: .white,
                          brightness: 100, description: "Sunset"),
            LEDTransition(date: day.sunset.addingTimeInterval(3600), mode: .amber,
                          brightness: 255, description: "Sunset + 1h"),
            LEDTransition(date: day.sunset.addingTimeInterval(late ? 10800 : 14400),
                          mode: .amber, brightness: 33,
                          description: late ? "Sunset + 3h (late sunset)" : "Sunset + 4h")
        ]
    }
    events.sort { $0.date < $1.date }
    guard let active = events.last(where: { $0.date <= now }) else {
        throw ToolError("No solar transition before current time in the available schedule")
    }
    return AutomaticPlan(source: source, zone: zone, days: days, events: events,
                         target: active, next: events.first(where: { $0.date > now }))
}

func solarFormatter(_ zone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return formatter
}

func previewAutomaticLED(location: SolarLocation? = nil) throws {
    let now = Date()
    let plan = try calculateAutoPlan(at: now, location: location)
    let f = solarFormatter(plan.zone)
    let cal = configuredCalendar(plan.zone)
    let today = cal.startOfDay(for: now)
    print("Solar source: \(plan.source)")
    print("Current time: \(f.string(from: now))")
    for day in plan.days where cal.isDate(day.sunrise, inSameDayAs: today) {
        print("Sunrise: \(f.string(from: day.sunrise))")
        print("Sunset:  \(f.string(from: day.sunset))")
    }
    print("Today's transitions:")
    // Show transitions anchored to today's sunrise or sunset even if an event
    // occurs after midnight, by matching source daytime to its solar day.
    for day in plan.days where cal.isDate(day.sunrise, inSameDayAs: today) {
        for event in plan.events where event.date >= day.sunrise.addingTimeInterval(-3600)
                              && event.date <= day.sunset.addingTimeInterval(14400) {
            print("  \(f.string(from: event.date))  \(event.mode.rawValue) \(event.brightness)  [\(event.description)]")
        }
    }
    print("Target now: \(plan.target.mode.rawValue) \(plan.target.brightness)")
    if let next = plan.next {
        print("Next transition: \(f.string(from: next.date))  \(next.mode.rawValue) \(next.brightness)")
    } else { print("Next transition unavailable: CoreBrightness did not provide enough future events") }
    print("Dry run only: no SMC write performed.")
}

// Smoothstep makes a 3-second fade ease both into and out of its endpoint.
func fadeBrightness(_ smc: SMC, from start: UInt8, to end: UInt8,
                    duration: TimeInterval, steps: Int = 20) throws {
    guard steps > 0 else { return }
    if start == end { return }
    let stepDuration = duration / Double(steps)
    let beginning = Date()
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let eased = t*t*(3.0 - 2.0*t)
        let level = UInt8(max(0, min(255, Int((Double(start) +
                                            (Double(end) - Double(start))*eased).rounded()))))
        try smc.write("LSLN", bytes: [level, level])
        let remaining = beginning.addingTimeInterval(stepDuration * Double(i)).timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }
}

func applyAutomaticLED(_ smc: SMC) throws {
    try requireRoot()
    try requireSupportedLEDHost(smc: smc)
    try checkLEDKeys(smc, includeModes: true)
    let target = try calculateAutoPlan(at: Date()).target
    let current = try readLEDOutput(smc)
    guard current.selection == [0] || current.selection == [1] else {
        throw ToolError("Unexpected LED channel selector \(hex(current.selection)); refusing automatic mode")
    }
    guard current.brightness.count == 2, current.brightness[0] == current.brightness[1] else {
        throw ToolError("Unexpected LSLN \(hex(current.brightness)); refusing automatic fade")
    }
    let currentMode: LEDMode = current.selection == [0] ? .white : .amber
    let currentLevel = current.brightness[0]
    if currentMode == target.mode && currentLevel == target.brightness { return }

    if currentMode == target.mode {
        try fadeBrightness(smc, from: currentLevel, to: target.brightness, duration: 3.0)
    } else {
        // Color presets are exclusive on M1 Mac mini. Fade out first, switch
        // while dark, then fade in; never attempt simultaneous channel writes.
        try fadeBrightness(smc, from: currentLevel, to: 0, duration: 1.5, steps: 10)
        if target.mode == .white { try restoreWhiteChannel(smc) }
        else { try smc.write("LSSB", bytes: [4, 0]) }
        try smc.write("LSLN", bytes: [0, 0])
        try fadeBrightness(smc, from: 0, to: target.brightness, duration: 1.5, steps: 10)
    }
    let final = try readLEDOutput(smc)
    guard final.selection == (target.mode == .white ? [0] : [1]),
          final.brightness == [target.brightness, target.brightness] else {
        throw ToolError("Automatic transition finished but SMC readback differs: LSCS=\(hex(final.selection)), LSLN=\(hex(final.brightness))")
    }
    print("Auto LED: \(currentMode.rawValue) \(currentLevel) -> \(target.mode.rawValue) \(target.brightness)")
}

// Hardware zero test must be performed before relying on darkness at an
// intermediate color-switch moment. Uses only already verified controls.
func testZeroBrightness() throws {
    try requireRoot()
    try requireM1Mini()
    let smc = try SMC()
    try checkLEDKeys(smc, includeModes: true)
    let original = try readLEDOutput(smc)
    guard original.selection == [0], original.amberPWM == [0, 0] else {
        throw ToolError("Begin in white mode for reversible zero test: sudo ./smcled --white")
    }
    let cancellation = DiagnosticCancellation()
    print("Temporary zero-brightness test. Please observe whether each LED turns completely off.")
    defer {
        do {
            try restoreWhiteChannel(smc)
            try smc.write("LSLN", bytes: original.brightness)
            print("Restored white, LSLN=\(hex(try smc.read("LSLN")))")
        } catch { writeStderr("WARNING: zero-test restoration failed: \(error)\n") }
    }
    try smc.write("LSLN", bytes: [100, 100])
    try cancellation.pause(0.7)
    try smc.write("LSLN", bytes: [0, 0])
    try cancellation.pause(1.0)
    print("White at 0: LS0P=\(hex(try smc.read("LS0P"))) LSLN=\(hex(try smc.read("LSLN")))")
    try smc.write("LSSB", bytes: [4, 0])
    try smc.write("LSLN", bytes: [100, 100])
    try cancellation.pause(0.7)
    try smc.write("LSLN", bytes: [0, 0])
    try cancellation.pause(1.0)
    print("Amber at 0: LS1P=\(hex(try smc.read("LS1P"))) LSLN=\(hex(try smc.read("LSLN")))")
    print("Confirm visually whether both modes were truly dark at brightness zero.")
}

func usage() {
    print("""
    smcled — AppleSMC status LED CLI for Mac mini and Mac Studio

      sudo smcled 10                      White at brightness 10
      sudo smcled --white [0...255]      White; optional brightness (current if omitted)
      sudo smcled --amber [0...255]      Steady amber; optional brightness
      sudo smcled --amber-blink [0...255]
                                          Single amber flashing
      sudo smcled --amber-double [0...255]
                                          Double amber flashing
      sudo smcled --off                  Turn LED off (white brightness 0)
      sudo smcled --reset                Default white brightness (255)
      sudo smcled --intel-brightness 50  Intel 2018: custom white brightness 0...255 (experimental)
      sudo smcled --intel-full           Intel 2018: force full-bright white
      sudo smcled --intel-restore        Intel 2018: return to system-controlled white
      smcled --intel-led-status          Intel 2018: read-only SIL state
      # Intel 2018: --off turns LED off; --reset or --white restores
      # Intel 2018: --white 50 or bare 50 also sets custom white level
      # Intel 2018: amber and installation remain disabled

      sudo smcled --install 10           Persist white brightness 10
      sudo smcled --install white 10     Persist white brightness 10
      sudo smcled --install amber 10     Persist steady amber brightness 10
      sudo smcled --install amber-blink 50
                                          Persist single flashing amber at 50
      sudo smcled --install amber-double 50
                                          Persist double flashing amber at 50
      sudo smcled --install-auto [seconds]
                                          Sunrise/sunset checks; 300s default (30...86400)
      smcled --auto-preview               Show today's solar events & LED plan
      smcled --auto-preview <lat> <lon> <IANA-timezone>
                                          Preview with explicit coordinates
      sudo smcled --auto-check            Apply appropriate state right now
      sudo smcled --test-zero             Reversible white/amber 0 test
      smcled --status                    Read configured settings; no sudo
      sudo smcled --uninstall            Remove daemon, files, symlink; reset LED

      smcled --compatibility             Read-only hardware capability report
      smcled --sample-brightness         Read LSLN repeatedly, without writes
      smcled --intel-snapshot              Read-only Intel SMC LED key inventory
      sudo smcled --intel-suite --confirm-hardware-test
                                          Three reversible Intel LSLN tests
      sudo smcled --intel-probe first 32 --confirm-hardware-test
      sudo smcled --intel-probe second 100 --confirm-hardware-test
                                          Select byte and value without recompiling
      sudo smcled --test-intel-brightness 100 --confirm-hardware-test
                                          Legacy second-byte test on Macmini8,1
      --accept-untested-model             Enable a matching but untested Apple Silicon
                                          mini/Studio (including future models)
      smcled --compatibility-self-test   Offline signature classification tests
      sudo smcled --test-brightness 100 --confirm-hardware-test
                                          Reversible LSLN probe on candidate models
      sudo smcled --test-studio-amber --confirm-hardware-test
                                          Reversible steady amber probe on Mac16,9
      smcled model                       Print hardware identifier
      smcled read <FOURCC>               Read an SMC key
      smcled info <FOURCC>               Read key metadata
      smcled scan [--all]                Enumerate keys (read only)
      sudo smcled --test-amber-brightness 10
                                          Temporary brightness/amber experiment
      sudo smcled --test-amber [4|8|9]   3-second reversible preset test
      sudo smcled --test-dual-channel     Sample white/amber PWM during switching
      sudo smcled led <KEY> <0...255> --confirm-led-key [--mode vv|v0]
      sudo smcled test <KEY> --confirm-led-key [--mode vv|v0]

    Brightness: integer 0...255. Without a value, amber commands retain
    the current LSLN brightness; --install <mode> without a value retains
    the saved brightness (or defaults to 255 on a new installation).
    Immediate changes do not modify the saved boot preference.
    Steady amber dimming confirmed on hardware; flashing dimming not yet tested.
    """)
}
func verifyLED(_ smc: SMC, key: String, args: [String]) throws -> String {
    guard modelID() == "Macmini9,1" else {
        throw ToolError("LED writes restricted to Macmini9,1; detected \(modelID())")
    }
    #if os(macOS)
    guard geteuid() == 0 else { throw ToolError("LED writes require sudo/root") }
    #endif
    guard args.contains("--confirm-led-key") else {
        throw ToolError("Refusing write without --confirm-led-key; do not guess the key")
    }
    let metadata = try smc.info(key)
    guard metadata.size == 2 else {
        throw ToolError("Refusing write: \(key) has size \(metadata.size), not 2 bytes")
    }
    guard metadata.writable else {
        throw ToolError("Refusing write: \(key) does not advertise write permission (attrs=\(String(format: "0x%02X", metadata.attributes)))")
    }
    let mode: String
    if let index = args.firstIndex(of: "--mode") {
        guard args.indices.contains(index + 1) else { throw ToolError("Expected vv or v0 after --mode") }
        mode = args[index + 1]
    } else {
        mode = "vv"
    }
    guard mode == "vv" || mode == "v0" else { throw ToolError("Mode must be vv or v0") }
    return mode
}

func ledBytes(_ value: UInt8, mode: String) -> [UInt8] {
    mode == "vv" ? [value, value] : [value, 0]
}

func run(_ originalArguments: [String]) throws {
    let arguments = originalArguments.filter { $0 != "--accept-untested-model" }
    guard let command = arguments.first else { usage(); return }
    if ["--help", "help", "-h"].contains(command) { usage(); return }
    if command == "model" { print(modelID()); return }
    switch command {
    case "--compatibility":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --compatibility") }
        try reportCompatibility()
        return
    case "--intel-led-status":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --intel-led-status") }
        try intelSILStatus()
        return
    case "--intel-brightness":
        guard arguments.count == 2 else { throw ToolError("Usage: sudo smcled --intel-brightness <0...255>") }
        guard modelID() == "Macmini8,1" else {
            throw ToolError("--intel-brightness is only supported on Macmini8,1")
        }
        try intelWriteBrightness(brightnessNumber(arguments[1]))
        return
    case "--intel-full", "--intel-restore", "--intel-off":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled \(command)") }
        try applyIntelSIL(command == "--intel-full" ? .full :
                          command == "--intel-restore" ? .normal : .off)
        return
    case "--intel-snapshot":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --intel-snapshot") }
        try intelReadOnlyDiagnostics()
        return
    case "--intel-suite":
        guard arguments.count == 2, arguments[1] == "--confirm-hardware-test" else {
            throw ToolError("Usage: sudo smcled --intel-suite --confirm-hardware-test")
        }
        try intelSuite()
        return
    case "--intel-probe":
        guard arguments.count == 4,
              let byte = IntelLSLNByte(rawValue: arguments[1]),
              arguments[3] == "--confirm-hardware-test" else {
            throw ToolError("Usage: sudo smcled --intel-probe <first|second> <0...255> --confirm-hardware-test")
        }
        try runIntelLSLNExperiments([
            IntelLSLNExperiment(byte: byte, value: try brightnessNumber(arguments[2]),
                                 label: "\(byte.rawValue) byte")
        ])
        return
    case "--test-intel-brightness":
        guard arguments.count == 3, arguments[2] == "--confirm-hardware-test" else {
            throw ToolError("Usage: sudo smcled --test-intel-brightness <0...255> --confirm-hardware-test")
        }
        try testIntelBrightnessCandidate(brightnessNumber(arguments[1]))
        return
    case "--sample-brightness":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --sample-brightness") }
        try sampleBrightnessRegister()
        return
    case "--compatibility-self-test":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --compatibility-self-test") }
        try compatibilitySelfTest()
        return
    case "--test-studio-amber":
        guard arguments.count == 2, arguments[1] == "--confirm-hardware-test" else {
            throw ToolError("Usage: sudo smcled --test-studio-amber --confirm-hardware-test")
        }
        try testStudioAmberCandidate()
        return
    case "--test-brightness":
        guard arguments.count == 3, arguments[2] == "--confirm-hardware-test" else {
            throw ToolError("Usage: sudo smcled --test-brightness <0...255> --confirm-hardware-test")
        }
        try testBrightnessCandidate(brightnessNumber(arguments[1]))
        return
    case "--auto-preview":
        guard arguments.count == 1 || arguments.count == 4 else {
            throw ToolError("Usage: smcled --auto-preview [<latitude> <longitude> <IANA-timezone>]")
        }
        let explicit: SolarLocation?
        if arguments.count == 4 {
            guard let lat = Double(arguments[1]), let lon = Double(arguments[2]),
                  let tz = TimeZone(identifier: arguments[3]) else {
                throw ToolError("Invalid explicit location/time zone")
            }
            explicit = try SolarLocation(latitude: lat, longitude: lon,
                                          timeZone: tz, label: "Explicit preview coordinates")
        } else { explicit = nil }
        try previewAutomaticLED(location: explicit)
        return
    case "--auto-check":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --auto-check") }
        try requireRoot()
        try requireSupportedLEDHost()
        try applyAutomaticLED(SMC())
        return
    case "--install-auto":
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: sudo smcled --install-auto [interval_seconds (30...86400)]")
        }
        let interval = try arguments.count == 2 ? autoIntervalSeconds(arguments[1]) : 300
        try installBrightness(255, automatic: true, interval: interval)
        return
    case "--test-zero":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --test-zero") }
        try testZeroBrightness()
        return
    case "--install":
        let args = Array(arguments.dropFirst())
        guard args.count >= 1 && args.count <= 2 else {
            throw ToolError("Usage: sudo smcled --install <0...255|white [0...255]|amber [0...255]|amber-blink [0...255]|amber-double [0...255]>")
        }
        // Accept both --install amber 10 and --install --amber 10.
        let selection = args[0].hasPrefix("--") ? String(args[0].dropFirst(2)) : args[0]
        if args.count == 1 && !selection.isEmpty && selection.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            try installBrightness(brightnessNumber(selection), mode: .white)
        } else if let mode = LEDMode(rawValue: selection) {
            let brightness = try args.count == 2 ? brightnessNumber(args[1]) : preferredBrightnessOrDefault()
            try installBrightness(brightness, mode: mode)
        } else {
            throw ToolError("Unknown install mode or brightness. See --help")
        }
        return
    case "--uninstall":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --uninstall") }
        try uninstallBrightness()
        return
    case "--off":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --off") }
        if modelID() == "Macmini8,1" {
            try applyIntelSIL(.off)
            return
        }
        try setKnownLEDBrightness(0)
        print("LED off; boot preference unchanged.")
        return
    case "--reset":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --reset") }
        if modelID() == "Macmini8,1" {
            try applyIntelSIL(.normal)
            return
        }
        try setKnownLEDBrightness(255)
        print("Restored normal white LED brightness (255); boot preference unchanged.")
        return
    case "--white":
        guard arguments.count == 1 || arguments.count == 2 else { throw ToolError("Usage: sudo smcled --white [0...255]") }
        if modelID() == "Macmini8,1" {
            if arguments.count == 1 { try applyIntelSIL(.normal) }
            else { try intelWriteBrightness(brightnessNumber(arguments[1])) }
            return
        }
        let brightness = try arguments.count == 2 ? brightnessNumber(arguments[1]) : nil
        let smc = try SMC()
        try applyKnownLED(smc, mode: .white, brightness: brightness)
        print("Normal white LED restored\(brightness.map { " at brightness \($0)" } ?? ""); boot preference unchanged.")
        return
    case "--amber", "--amber-blink", "--amber-double":
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: sudo smcled \(command) [0...255]")
        }
        let brightness = try arguments.count == 2 ? brightnessNumber(arguments[1]) : nil
        let mode: LEDMode = command == "--amber" ? .amber : (command == "--amber-blink" ? .amberBlink : .amberDouble)
        let smc = try SMC()
        try applyKnownLED(smc, mode: mode, brightness: brightness)
        print("Applied \(mode.rawValue) LED behavior\(brightness.map { " at brightness \($0)" } ?? ""); boot preference unchanged.")
        return
    case "--test-dual-channel":
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled --test-dual-channel") }
        try testDualChannel()
        return
    case "--test-amber-brightness":
        guard arguments.count == 2 else { throw ToolError("Usage: sudo smcled --test-amber-brightness <0...255>") }
        try testAmberBrightness(brightnessNumber(arguments[1]))
        return
    case "--test-amber":
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: sudo smcled --test-amber [4|8|9]")
        }
        let mode: UInt8
        if arguments.count == 1 { mode = 8 }
        else {
            guard ["4", "8", "9"].contains(arguments[1]) else { throw ToolError("Test modes are 4, 8 or 9") }
            mode = UInt8(arguments[1])!
        }
        try testAmberChannel(mode: mode)
        return
    case "--status":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --status") }
        try installationStatus()
        return
    case "--apply-installed":
        guard arguments.count == 1 else { throw ToolError("Usage: smcled --apply-installed") }
        try applyInstalledBrightness()
        return
    default: break
    }

    // A bare number is an immediate, non-persistent brightness change.
    // --install is the explicit way to change the saved boot preference.
    if command.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
        guard arguments.count == 1 else { throw ToolError("Usage: sudo smcled <0...255>") }
        let brightness = try brightnessNumber(command)
        if modelID() == "Macmini8,1" {
            try intelWriteBrightness(brightness)
        } else {
            try setKnownLEDBrightness(brightness)
            print("LED brightness set to \(brightness) (\(hex([brightness, brightness]))). Saved boot preference, if installed, was not changed.")
        }
        return
    }

    let smc = try SMC()
    switch command {
    case "info":
        guard arguments.count == 2 else { throw ToolError("Usage: smcled info <FOURCC>") }
        let info = try smc.info(arguments[1])
        print("\(arguments[1])  size=\(info.size)  type=\(info.type.debugDescription)  attrs=\(String(format: "0x%02X", info.attributes))  readable=\(info.readable)  writable=\(info.writable)")
    case "read":
        guard arguments.count == 2 else { throw ToolError("Usage: smcled read <FOURCC>") }
        let info = try smc.info(arguments[1])
        let value = try smc.read(arguments[1])
        print("\(arguments[1])  type=\(info.type.debugDescription)  raw=\(hex(value))")
    case "scan":
        guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--all") else {
            throw ToolError("Usage: smcled scan [--all]")
        }
        let all = arguments.contains("--all")
        let count = try smc.keyCount()
        print("SMC keys: \(count); \(all ? "all metadata" : "writable two-byte metadata"); read-only enumeration")
        var errors = 0
        for i in 0..<count {
            do {
                let key = try smc.keyAt(i)
                let info = try smc.info(key)
                if all || (info.size == 2 && info.writable) {
                    print(String(format: "%4d", i) + "  \(key)  size=\(info.size)  type=\(info.type.debugDescription)  attrs=\(String(format: "0x%02X", info.attributes))")
                }
            } catch { errors += 1 }
        }
        if errors > 0 { print("\(errors) keys could not be inspected") }
        print("WARNING: Candidate enumeration does not identify the LED. Never blindly test keys.")
    case "led":
        guard arguments.count >= 4 else { throw ToolError("Usage: sudo smcled led <KEY> <0...255> --confirm-led-key [--mode vv|v0]") }
        let key = arguments[1]
        guard let numeric = UInt8(arguments[2]) else { throw ToolError("Brightness must be 0...255") }
        let mode = try verifyLED(smc, key: key, args: Array(arguments.dropFirst(3)))
        try smc.write(key, bytes: ledBytes(numeric, mode: mode))
        print("SMC write sent: \(key) <- \(hex(ledBytes(numeric, mode: mode))) (not independently verified by this tool)")
    case "test":
        guard arguments.count >= 3 else { throw ToolError("Usage: sudo smcled test <KEY> --confirm-led-key [--mode vv|v0]") }
        let key = arguments[1]
        let mode = try verifyLED(smc, key: key, args: Array(arguments.dropFirst(2)))
        // Refuse to test write-only keys because we cannot restore unknown original data.
        let original = try smc.read(key)
        guard original.count == 2 else { throw ToolError("Cannot back up original LED key value") }
        print("Original \(key): \(hex(original)). Brief 32 -> 192 brightness test, then restore.")
        // Best effort restoration also on errors. A crash/power failure cannot be handled.
        defer {
            do { try smc.write(key, bytes: original); print("Restored \(key): \(hex(original))") }
            catch { writeStderr("WARNING: RESTORE FAILED: \(error)\n") }
        }
        try smc.write(key, bytes: ledBytes(32, mode: mode))
        Thread.sleep(forTimeInterval: 1.2)
        try smc.write(key, bytes: ledBytes(192, mode: mode))
        Thread.sleep(forTimeInterval: 1.2)
    default:
        throw ToolError("Unknown command: \(command). Use --help.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    writeStderr("smcled: \(error)\n")
    exit(1)
}
