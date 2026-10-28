import Foundation
import Darwin

struct BridgeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ScanCancellation {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// All operations except the cancellation flag run on a single background queue.
final class SerialBridge {
    private var fd: Int32 = -1
    private var incoming = [UInt8]()
    private(set) var remoteID: String?

    func connect(_ path: String) throws -> String? {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw BridgeFailure(message: "无法打开串口：\(String(cString: strerror(errno)))") }
        do {
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else { throw ioError("读取串口设置失败") }
            cfmakeraw(&settings)
            cfsetispeed(&settings, speed_t(B115200))
            cfsetospeed(&settings, speed_t(B115200))
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
            settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
            guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw ioError("配置串口失败") }
            // Give the Nano time to finish its bootloader if opening reset it.
            Thread.sleep(forTimeInterval: 2)
            tcflush(fd, TCIFLUSH)
            _ = try command("PING", expected: "READY")
            let id = String(try command("GET_ID", expected: "ID:").dropFirst(3))
            remoteID = isID(id) ? id : nil
            return remoteID
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func ioError(_ message: String) -> BridgeFailure {
        BridgeFailure(message: "\(message)：\(String(cString: strerror(errno)))")
    }

    private func writeLine(_ line: String) throws {
        let bytes = Array((line + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if n > 0 { written += n }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(10_000) }
            else { throw ioError("发送失败") }
        }
    }

    private func readLine(until deadline: Date) throws -> String? {
        while Date() < deadline {
            if let end = incoming.firstIndex(of: 10) {
                let result = String(decoding: incoming[..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                incoming.removeFirst(end + 1)
                return result
            }
            var buffer = [UInt8](repeating: 0, count: 128)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { incoming.append(contentsOf: buffer.prefix(n)) }
            else if n == 0 || errno == EAGAIN || errno == EINTR { usleep(10_000) }
            else { throw ioError("读取串口失败") }
        }
        return nil
    }

    private func command(_ command: String, expected: String = "OK") throws -> String {
        try writeLine(command)
        let deadline = Date().addingTimeInterval(5)
        while let line = try readLine(until: deadline) {
            if line.hasPrefix("ERR") { throw BridgeFailure(message: line) }
            if line.hasPrefix(expected) { return line }
            // Ignore startup banners and queued duplicate scan packets.
        }
        throw BridgeFailure(message: "设备没有回复 \(command)")
    }

    private func isID(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){2}$", options: .regularExpression) != nil
    }

    func scan(cancel: ScanCancellation) throws -> String? {
        _ = try command("SCAN")
        var found: String?
        var failure: Error?
        do {
            // Keep listening until a validated remote packet arrives or the
            // user explicitly stops scanning; a long idle period is normal.
            while !cancel.get() {
                guard let line = try readLine(until: Date().addingTimeInterval(0.1)) else { continue }
                if line.hasPrefix("ERR") { throw BridgeFailure(message: line) }
                if line.hasPrefix("FOUND:") {
                    let candidate = String(line.dropFirst(6)).uppercased()
                    if isID(candidate) { found = candidate; break }
                }
            }
        } catch { failure = error }
        do { _ = try command("SCAN_STOP") }
        catch { if failure == nil { failure = error } }
        if let failure = failure { throw failure }
        if let found = found {
            _ = try command("ID " + found)
            remoteID = found
        }
        return found
    }

    func send(_ value: String) throws {
        guard remoteID != nil else { throw BridgeFailure(message: "请先读取原遥控器") }
        _ = try command(value)
    }

    // Based on lamperez/xiaomi-lightbar-nrf24: an out-of-range downward
    // command anchors the value at the minimum; the next upward command
    // commits the desired 0...15 level without depending on stale state.
    func setLevel(_ level: Int, commandByte: UInt8) throws {
        guard (0...15).contains(level), commandByte == 0x04 || commandByte == 0x02 else {
            throw BridgeFailure(message: "调节值不正确")
        }
        try send(String(format: "CMD %02X F0", Int(commandByte)))
        try send(String(format: "CMD %02X %02X", Int(commandByte), level))
    }

    // The caller decides when to pair; the lamp must be power-cycled first.
    func pair(id: String) throws {
        guard isID(id) else { throw BridgeFailure(message: "遥控编号格式不正确") }
        _ = try command("ID " + id)
        remoteID = id
        _ = try command("PAIR")
    }
}
