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
        // On the Intel T2 mini the output visibly fades back on; a read
        // 0.5s after LSRB is often still mid-ramp, not a restoration failure.
        // Poll for up to 6 seconds, without treating the expected fade as an
        // error or interrupting restoration on SIGINT/SIGTERM.
        let deadline = Date().addingTimeInterval(6.0)
        var lastStatus = [UInt8]()
        var lastPWM = [UInt8]()
        var restored = false
        repeat {
            lastStatus = try smc.read("LSOF")
            lastPWM = try smc.read("LSPV")
            print("  Restoring: LSPV=\(hex(lastPWM)) LSOF=\(hex(lastStatus))")
            if lastStatus == [0], lastPWM == originalPWM,
               try smc.read("LSLN") == [0x2F, 0xFF],
               try smc.read("LS! ") == [0] {
                restored = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        guard restored else {
            throw TestError("LSRB restoration not confirmed within 6s (LSOF=\(hex(lastStatus)), LSPV=\(hex(lastPWM)), expected LSPV=\(hex(originalPWM))); inspect LED and STOP")
        }
        print("  Reported SMC state restored after fade. Verify physical LED visually.")
    } catch {
        err("WARNING: restore via LSRB failed: \(error). Inspect the LED immediately.\n")
        throw error
    }
    if let stepError { throw stepError }
}
// Research-only candidate, NOT a verified Intel color command.
// J174 MacEFI references LSSB, while Apple Silicon hardware confirmed
// LSSB [04 00] as steady amber. The mapping on T2 is UNKNOWN. It must
// never be applied as a normal color mode unless physically verified.
func testAmberCandidate(_ smc: SMC, cancellation: Cancellation) throws {
    try checkKey(smc, "LSSB", size: 2, type: "hex_", readable: false, writable: true)
    guard try smc.read("LSLN") == [0x2F, 0xFF],
          try smc.read("LSOF") == [0],
          try smc.read("LSPV") == [0x14, 0x11],
          try smc.read("LS! ") == [0] else {
        throw TestError("Amber experiment requires the verified normal-white baseline")
    }
    print("\nUNVERIFIED Intel amber candidate: LSSB=04 00 for 2 seconds.")
    print("Watch the LED color. SMC PWM readback cannot establish whether it is amber.")
    var writeError: Error?
    do {
        try cancellation.check()
        try smc.write("LSSB", bytes: [4, 0])
        for index in 1...8 {
            try cancellation.pause(0.25)
            print("  +\(Double(index) * 0.25)s LSPV=\(hex(try smc.read("LSPV"))) LSOF=\(hex(try smc.read("LSOF")))")
        }
    } catch { writeError = error }
    // Attempt restoration even if the write or sampling fails.
    try smc.write("LSRB", bytes: [0])
    let deadline = Date().addingTimeInterval(6)
    var restored = false
    repeat {
        let status = try smc.read("LSOF")
        let pwm = try smc.read("LSPV")
        print("  Restoring: LSPV=\(hex(pwm)) LSOF=\(hex(status))")
        if status == [0], pwm == [0x14, 0x11],
           try smc.read("LSLN") == [0x2F, 0xFF],
           try smc.read("LS! ") == [0] {
            restored = true
            break
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    guard restored else {
        throw TestError("Amber candidate: baseline not confirmed after LSRB; inspect physical LED and STOP")
    }
    print("Normal-white SMC telemetry restored. Was the LED amber, white, or unchanged?")
    if let writeError { throw writeError }
}
// Research-only Intel brightness candidate. LSLB is the historical "Full On"
// PWM preset, and LSOO=1 was physically verified to force full-white on this
// exact Macmini8,1. Whether modifying LSLB changes physical brightness remains
// UNKNOWN. A single half-scale value is tried, restored unconditionally.
func testFullBrightnessCandidate(_ smc: SMC, cancellation: Cancellation) throws {
    try checkKey(smc, "LSLB", size: 2, type: "ui16", readable: true, writable: true)
    try checkKey(smc, "LSSV", size: 2, type: "ui16", readable: true, writable: true)
    let original = try smc.read("LSLB")
    guard original == [0xFF, 0xFF],
          try smc.read("LSSV") == [0x08, 0x6B],
          try smc.read("LSLN") == [0x2F, 0xFF],
          try smc.read("LSPV") == [0x14, 0x11],
          try smc.read("LSOF") == [0],
          try smc.read("LS! ") == [0] else {
        throw TestError("LSLB test requires exact verified normal-white baseline; no SMC writes attempted")
    }
    let candidate: [UInt8] = [0x7F, 0xFF]
    print("\nUNVERIFIED Intel variable-brightness experiment:")
    print("  Set LSLB FF FF -> 7F FF (approximately half of raw full-on preset).")
    print("  Then invoke verified LSOO=1 for 2s; measure LSPV and observe the physical LED.")
    print("  Always restore LSLB=FF FF, then LSRB=0 and check normal-white telemetry.")
    var testFailure: Error?
    do {
        try cancellation.check()
        try smc.write("LSLB", bytes: candidate)
        let echo = try smc.read("LSLB")
        guard echo == candidate else {
            throw TestError("LSLB readback mismatch: \(hex(echo))")
        }
        print("  LSLB readback: \(hex(echo))")
        try smc.write("LSOO", bytes: [1])
        for i in 1...8 {
            try cancellation.pause(0.25)
            let pwm = try smc.read("LSPV")
            let off = try smc.read("LSOF")
            print("  +\(Double(i) * 0.25)s LSPV=\(hex(pwm)) LSOF=\(hex(off))")
        }
    } catch { testFailure = error }

    // Restore each register independently, even if the other write fails.
    // Crucially, restore LSLB before LSRB re-enables firmware behavior.
    var restorationErrors: [String] = []
    do { try smc.write("LSLB", bytes: original) }
    catch {
        restorationErrors.append("LSLB: \(error)")
        err("WARNING: restoring LSLB failed: \(error)\n")
    }
    do { try smc.write("LSRB", bytes: [0]) }
    catch {
        restorationErrors.append("LSRB: \(error)")
        err("WARNING: restoring normal LED mode failed: \(error)\n")
    }
    let deadline = Date().addingTimeInterval(6.0)
    var restored = false
    repeat {
        do {
            let p = try smc.read("LSPV")
            let off = try smc.read("LSOF")
            let full = try smc.read("LSLB")
            print("  Restoring: LSLB=\(hex(full)) LSPV=\(hex(p)) LSOF=\(hex(off))")
            if full == original, p == [0x14, 0x11], off == [0],
               try smc.read("LSLN") == [0x2F, 0xFF],
               try smc.read("LS! ") == [0] {
                restored = true
                break
            }
        } catch {
            restorationErrors.append("verification: \(error)")
            break
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    guard restored && restorationErrors.isEmpty else {
        throw TestError("Full-on brightness test: restoration not confirmed (\(restorationErrors.joined(separator: "; "))); STOP, inspect LED")
    }
    print("  Original LSLB, normal PWM and LED-on flag confirmed restored.")
    if let testFailure { throw testFailure }
    print("  Hardware telemetry test completed. Please report visible brightness relative to normal/full white.")
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1 || args.count == 2 else {
        throw TestError("Usage: ./intel-sil-probe --snapshot | sudo ./intel-sil-probe --test-off|--test-on|--test-amber|--test-full-dim|--suite --confirm-hardware-test")
    }
    guard modelID() == "Macmini8,1" else { throw TestError("Only Macmini8,1 is supported") }
    let smc = try SMC()
    if args == ["--snapshot"] {
        snapshot(smc, heading: "Intel SIL state (read only):")
        return
    }
    guard args.count == 2, args[1] == "--confirm-hardware-test",
          ["--test-off", "--test-on", "--test-amber", "--test-full-dim", "--suite"].contains(args[0]) else {
        throw TestError("Invalid command or missing explicit confirmation")
    }
    try preflight(smc)
    let cancellation = Cancellation()
    snapshot(smc, heading: "Baseline before experimental on/off control:")
    // Each test stage attempts LSRB restoration. Do not blindly issue a
    // second LSRB: that can restart a legitimate fade-in. Use an additional
    // emergency LSRB only when the hardware still reports the LED off.
    defer {
        do {
            if try smc.read("LSOF") == [1] {
                err("WARNING: LED still reported off; attempting emergency LSRB restore.\n")
                try smc.write("LSRB", bytes: [0])
                Thread.sleep(forTimeInterval: 1.0)
            }
            snapshot(smc, heading: "Final post-test snapshot:")
        } catch { err("WARNING: final state inspection/emergency restore failed: \(error)\n") }
    }
    if args[0] == "--test-amber" {
        try testAmberCandidate(smc, cancellation: cancellation)
    } else if args[0] == "--test-full-dim" {
        try testFullBrightnessCandidate(smc, cancellation: cancellation)
    } else {
        let commands: [UInt8] = args[0] == "--suite" ? [0, 1] : [args[0] == "--test-off" ? 0 : 1]
        for value in commands { try test(smc, command: value, cancellation: cancellation) }
    }
    print("Finished. No persistent settings were installed.")
}
do { try run() }
catch { err("intel-sil-probe: \(error)\n"); exit(1) }
