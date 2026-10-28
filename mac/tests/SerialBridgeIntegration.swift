import Foundation

@main
struct SerialBridgeIntegration {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("expected pseudo-terminal and mode") }
        let bridge = SerialBridge()
        defer { bridge.close() }
        guard try bridge.connect(CommandLine.arguments[1]) == nil else { fatalError("expected no stored ID") }
        if CommandLine.arguments[2] == "pair" {
            try bridge.pair(id: "12:34:56")
            try bridge.send("ON")
        } else if CommandLine.arguments[2] == "sliders" {
            guard try bridge.scan(cancel: ScanCancellation()) == "0A:05:F1" else { fatalError("scan failed") }
            try bridge.setLevel(0, commandByte: 0x04)
            try bridge.setLevel(15, commandByte: 0x04)
            try bridge.setLevel(7, commandByte: 0x02)
            do {
                try bridge.setLevel(16, commandByte: 0x04)
                fatalError("invalid level was accepted")
            } catch is BridgeFailure { }
        } else {
            guard try bridge.scan(cancel: ScanCancellation()) == "0A:05:F1" else { fatalError("scan failed") }
            try bridge.send("BRIGHT +3")
        }
        print("native serial integration passed")
    }
}
