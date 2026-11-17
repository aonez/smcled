// Standalone Macmini8,1 experimental SIL state probe.
// Research-only utility: separate from smcled's normal LED-control commands.
// No installation or persistent configuration.
// Based on historical LS{OO,RB} key descriptions; T2 semantics unverified.
import Foundation
import Dispatch
#if os(macOS)
import Darwin
import IOKit
#endif

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func err(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
func fourCC(_ string: String) throws -> UInt32 {
    let bytes = Array(string.utf8)
    guard bytes.count == 4, bytes.allSatisfy({ (32...126).contains($0) }) else {
        throw TestError("Expected four printable ASCII bytes for SMC key")
    }
    return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}
func fourCCString(_ key: UInt32) -> String {
    String(decoding: [UInt8((key >> 24) & 255), UInt8((key >> 16) & 255),
                      UInt8((key >> 8) & 255), UInt8(key & 255)], as: UTF8.self)
}
func putU32(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
    for i in 0..<4 { buffer[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(i * 8)) }
}
func getU32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(buffer[offset + $1]) << UInt32($1 * 8)) }
}
struct KeyInfo {
    let size: UInt32
    let type: String
    let attrs: UInt8
    var readable: Bool { (attrs & 0x80) != 0 }
    var writable: Bool { (attrs & 0x40) != 0 }
}
final class SMC {
    #if os(macOS)
    private var connection: io_connect_t = 0
    #endif
    init() throws {
        #if os(macOS)
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TestError("AppleSMC service not found") }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == KERN_SUCCESS else { throw TestError("IOServiceOpen failed: \(status)") }
        #else
        throw TestError("This diagnostic requires macOS")
        #endif
    }
    deinit {
        #if os(macOS)
        if connection != 0 { IOServiceClose(connection) }
        #endif
    }
    private func call(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count == 80 else { throw TestError("Invalid SMC request") }
        #if os(macOS)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let status = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, 2, inp.baseAddress, 80,
                                          out.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS && outputSize == 80 else {
            throw TestError("SMC transport error: \(status), response size \(outputSize)")
        }
        guard output[40] == 0 else {
            throw TestError(String(format: "SMC operation rejected: 0x%02X", output[40]))
        }
        return output
        #else
        throw TestError("This diagnostic requires macOS")
        #endif
    }
    func info(_ key: String) throws -> KeyInfo {
        var req = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &req)
        req[42] = 9
        let res = try call(req)
        return KeyInfo(size: getU32(res, at: 28), type: fourCCString(getU32(res, at: 32)), attrs: res[36])
    }
    func read(_ key: String) throws -> [UInt8] {
        let metadata = try info(key)
        guard metadata.readable, metadata.size <= 32 else {
            throw TestError("SMC key \(key) is not readable")
        }
        var req = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &req)
        putU32(metadata.size, at: 28, in: &req)
        req[42] = 5
        let res = try call(req)
        return Array(res[48..<(48 + Int(metadata.size))])
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        let metadata = try info(key)
        guard metadata.writable, metadata.size == bytes.count,
              (1...2).contains(bytes.count) else {
            throw TestError("SMC key \(key) has unexpected size/permissions; no write")
        }
        var req = [UInt8](repeating: 0, count: 80)
        putU32(try fourCC(key), at: 0, in: &req)
        putU32(metadata.size, at: 28, in: &req)
        req[42] = 6
        for (i, byte) in bytes.enumerated() { req[48+i] = byte }
        _ = try call(req)
    }
}
func modelID() -> String {
    #if os(macOS)
    var n = 0
    guard sysctlbyname("hw.model", nil, &n, nil, 0) == 0, n > 0 else { return "unknown" }
    var chars = [CChar](repeating: 0, count: n)
    let code = chars.withUnsafeMutableBufferPointer {
        sysctlbyname("hw.model", $0.baseAddress, &n, nil, 0)
    }
    return code == 0 ? String(cString: chars) : "unknown"
    #else
    return "unsupported"
    #endif
}
func checkKey(_ smc: SMC, _ key: String, size: UInt32, type: String,
              readable: Bool, writable: Bool) throws {
    let m = try smc.info(key)
    guard m.size == size, m.type == type,
          m.readable == readable, m.writable == writable else {
        throw TestError("Unexpected metadata for \(key): size=\(m.size), type=\(m.type), attrs=\(String(format:"%02X",m.attrs)); no writes")
    }
}
func snapshot(_ smc: SMC, heading: String) {
    print(heading)
    for key in ["LSLN", "LSLB", "LSLF", "LSPV", "LSOF", "LS! ", "LSB!"] {
        do { print("  \(key): \(hex(try smc.read(key)))") }
        catch { print("  \(key): unavailable (\(error))") }
    }
}
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var sources: [DispatchSourceSignal] = []
    init() {
        #if os(macOS)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig,
                    queue: DispatchQueue(label: "smcled.intel.probe.signal.\(sig)"))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.requested = true
                self.lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
        #endif
    }
    func check() throws {
        lock.lock(); let cancelled = requested; lock.unlock()
        if cancelled { throw TestError("Interrupted; restoring normal LED behavior") }
    }
    func pause(_ seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try check()
            Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
        }
        try check()
    }
}
func preflight(_ smc: SMC) throws {
    #if os(macOS)
    guard geteuid() == 0 else { throw TestError("The write test requires sudo") }
    #endif
    guard modelID() == "Macmini8,1" else {
        throw TestError("Restricted to Macmini8,1")
    }
    try checkKey(smc, "LSOO", size: 1, type: "flag", readable: false, writable: true)
    try checkKey(smc, "LSRB", size: 1, type: "flag", readable: false, writable: true)
    try checkKey(smc, "LSLN", size: 2, type: "ui16", readable: true, writable: true)
    try checkKey(smc, "LSPV", size: 2, type: "ui16", readable: true, writable: false)
    try checkKey(smc, "LSOF", size: 1, type: "flag", readable: true, writable: false)
    try checkKey(smc, "LS! ", size: 1, type: "ui8 ", readable: true, writable: true)
    guard try smc.read("LSLN") == [0x2F, 0xFF],
          try smc.read("LSOF") == [0],
          try smc.read("LS! ") == [0] else {
        throw TestError("Macmini8,1 LED is not at the observed baseline; no write attempted")
    }
}
func test(_ smc: SMC, command: UInt8, cancellation: Cancellation) throws {
    try cancellation.check()
    guard try smc.read("LSLN") == [0x2F, 0xFF],
          try smc.read("LSOF") == [0] else {
        throw TestError("Baseline changed; stopping the sequence")
    }
    print("\nExperiment LSOO=\(command) (\(command == 0 ? "request off" : "request full on")) for 2 seconds")
    let originalPWM = try smc.read("LSPV")
    print("  Before: LSPV=\(hex(originalPWM)) LSOF=\(hex(try smc.read("LSOF")))")
    // Always attempt to restore SMC-defined behavior, even if the command fails.
    var stepError: Error?
    do {
        try smc.write("LSOO", bytes: [command])
        try cancellation.pause(0.2)
        print("  During: LSPV=\(hex(try smc.read("LSPV"))) LSOF=\(hex(try smc.read("LSOF")))")
        try cancellation.pause(1.8)
    } catch { stepError = error }
    do {
        try smc.write("LSRB", bytes: [0])
        try cancellation.pause(0.5)
        print("  After LSRB: LSPV=\(hex(try smc.read("LSPV"))) LSOF=\(hex(try smc.read("LSOF")))")
        let status = try smc.read("LSOF")
        let pwm = try smc.read("LSPV")
        guard status == [0], pwm == originalPWM,
              try smc.read("LSLN") == [0x2F, 0xFF],
              try smc.read("LS! ") == [0] else {
            throw TestError("SMC did not return to baseline after LSRB (LSOF=\(hex(status)), LSPV=\(hex(pwm))); STOP")
        }
        print("  Reported SMC state restored. Verify physical LED visually.")
    } catch {
        err("WARNING: restore via LSRB failed: \(error). Inspect the LED immediately.\n")
        throw error
    }
    if let stepError { throw stepError }
}
func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1 || args.count == 2 else {
        throw TestError("Usage: ./intel-sil-probe --snapshot | sudo ./intel-sil-probe --test-off|--test-on|--suite --confirm-hardware-test")
    }
    guard modelID() == "Macmini8,1" else { throw TestError("Only Macmini8,1 is supported") }
    let smc = try SMC()
    if args == ["--snapshot"] {
        snapshot(smc, heading: "Intel SIL state (read only):")
        return
    }
    guard args.count == 2, args[1] == "--confirm-hardware-test",
          ["--test-off", "--test-on", "--suite"].contains(args[0]) else {
        throw TestError("Invalid command or missing explicit confirmation")
    }
    try preflight(smc)
    let cancellation = Cancellation()
    snapshot(smc, heading: "Baseline before experimental on/off control:")
    // Independent fallback in addition to the restoration after each stage.
    defer {
        do {
            try smc.write("LSRB", bytes: [0])
            snapshot(smc, heading: "Final post-test snapshot:")
        } catch { err("WARNING: final LSRB restore failed: \(error)\n") }
    }
    let commands: [UInt8] = args[0] == "--suite" ? [0, 1] : [args[0] == "--test-off" ? 0 : 1]
    for value in commands { try test(smc, command: value, cancellation: cancellation) }
    print("Finished. No persistent settings were installed.")
}
do { try run() }
catch { err("intel-sil-probe: \(error)\n"); exit(1) }
