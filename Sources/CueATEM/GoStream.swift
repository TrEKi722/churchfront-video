import Foundation

// OSEE GoStream (Deck, Duet) control over TCP. Protocol notes come from the
// community Bitfocus Companion module (MIT), not from OSEE documentation.
//
// Frame: 0xEB 0xA6 | protoid (0) | length (UInt16 LE, bytes after this header
// up to and including the CRC) | JSON {"id","type","value"} | CRC-16 Modbus (LE).
// One TCP read can hold several frames, and a frame can be split across reads.

public enum GoStreamReqType: String {
    case get = "get"
    case set = "set"
    case push = "pus"
    /// The switcher's answer to something it didn't understand (for example PARSE_ERROR_NOT_FOND_ID).
    case error = "err"
}

public struct GoStreamCommand: Equatable {
    public var id: String
    public var type: GoStreamReqType
    public var value: [GoStreamValue]?

    public init(id: String, type: GoStreamReqType, value: [GoStreamValue]? = nil) {
        self.id = id
        self.type = type
        self.value = value
    }
}

/// Values in a command are JSON numbers or strings.
public enum GoStreamValue: Equatable {
    case number(Double)
    case string(String)
}

public enum GoStreamCodec {
    static let head: [UInt8] = [0xEB, 0xA6]
    static let protoID: UInt8 = 0x00
    static let headerSize = 5
    static let crcSize = 2

    /// CRC-16 Modbus: poly 0xA001 (reflected), initial 0xFFFF, no final XOR.
    public static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    public static func json(for command: GoStreamCommand) -> Data {
        var object: [String: Any] = ["id": command.id, "type": command.type.rawValue]
        if let value = command.value {
            object["value"] = value.map { v -> Any in
                switch v {
                case .number(let n): return n
                case .string(let s): return s
                }
            }
        }
        // Sorted keys keep the bytes stable for tests.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Wraps one command in a frame.
    public static func encode(_ command: GoStreamCommand) -> [UInt8] {
        let body = [UInt8](json(for: command))
        let length = body.count + crcSize // bytes after the 5-byte header, CRC included
        var frame: [UInt8] = head + [protoID, UInt8(length & 0xFF), UInt8(length >> 8)] + body
        let crc = crc16Modbus(frame)
        frame.append(UInt8(crc & 0xFF))
        frame.append(UInt8(crc >> 8))
        return frame
    }

    public static func encodeAll(_ commands: [GoStreamCommand]) -> [UInt8] {
        commands.flatMap { encode($0) }
    }
}

/// Splits a TCP byte stream into commands. Keeps any partial frame between calls.
public struct GoStreamDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed raw bytes; returns every complete, valid command found so far.
    /// Bad frames (wrong CRC, bad JSON) are dropped, and scanning resumes at the next header.
    public mutating func feed(_ bytes: [UInt8]) -> [GoStreamCommand] {
        buffer.append(contentsOf: bytes)
        var out: [GoStreamCommand] = []
        while true {
            guard let start = findHead(in: buffer, from: 0) else {
                // Keep a trailing 0xEB in case the header is split across reads.
                if let last = buffer.last, last == GoStreamCodec.head[0] {
                    buffer = [last]
                } else {
                    buffer.removeAll()
                }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= GoStreamCodec.headerSize else { break }
            let length = Int(buffer[3]) | Int(buffer[4]) << 8
            let total = GoStreamCodec.headerSize + length
            guard length > GoStreamCodec.crcSize else {
                buffer.removeFirst(2) // not a real header; keep scanning
                continue
            }
            guard buffer.count >= total else { break } // wait for the rest
            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if let command = GoStreamDecoder.parse(frame) {
                out.append(command)
            }
        }
        return out
    }

    private func findHead(in bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var i = from
        while i + 1 < bytes.count {
            if bytes[i] == GoStreamCodec.head[0] && bytes[i + 1] == GoStreamCodec.head[1] { return i }
            i += 1
        }
        return nil
    }

    /// Checks the CRC and decodes the JSON body of one complete frame.
    static func parse(_ frame: [UInt8]) -> GoStreamCommand? {
        let crcAt = frame.count - GoStreamCodec.crcSize
        let received = UInt16(frame[crcAt]) | UInt16(frame[crcAt + 1]) << 8
        guard received == GoStreamCodec.crc16Modbus(Array(frame[0..<crcAt])) else { return nil }
        let body = Array(frame[GoStreamCodec.headerSize..<crcAt])
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let id = object["id"] as? String,
              let typeName = object["type"] as? String,
              let type = GoStreamReqType(rawValue: typeName) else { return nil }
        var values: [GoStreamValue]?
        if let raw = object["value"] as? [Any] {
            values = raw.compactMap { item -> GoStreamValue? in
                if let n = item as? NSNumber, !(item is Bool) { return .number(n.doubleValue) }
                if let s = item as? String { return .string(s) }
                return nil
            }
        }
        return GoStreamCommand(id: id, type: type, value: values)
    }
}

/// Command IDs as the GoStream uses them on the wire. Names match the Companion module.
public enum GoStreamID {
    public static let pgmIndex = "pgmIndex"
    public static let pvwIndex = "pvwIndex"
    public static let cutTransition = "cutTransition"
    public static let autoTransition = "autoTransition"
    public static let transitionStatus = "transitionStatus"
    public static let ftb = "ftb"
    public static let ftbStatus = "ftbStatus"
    public static let inputList = "inputList"
    public static let deviceType = "deviceType"
    public static let deviceName = "deviceName"
    public static let version = "version"
    public static let transitionStyle = "transitionStyle"
    public static let transitionMixRate = "transitionMixRate"
    public static let transitionDipRate = "transitionDipRate"
    public static let transitionWipeRate = "transitionWipeRate"
    public static let previewTransition = "previewTransition"
    public static let liveStreamOutputEnable = "liveStreamOutputEnable"
    public static let liveStreamOutputKey = "liveStreamOutputKey"
    public static let liveStreamOutputServiceName = "liveStreamOutputServiceName"
    public static let liveStreamOutputUrl = "liveStreamOutputUrl"
    public static let liveStreamOutputStatus = "liveStreamOutputStatus"
    public static let liveStreamOutputBitrate = "liveStreamOutputBitrate"
    public static let live = "live"
    public static let recordStart = "recordStart"
    public static let recordStop = "recordStop"
    public static let recordStatus = "recordStatus"
    public static let recordFormat = "recordFormat"
    public static let recordBitrate = "recordBitrate"
}

/// Builders for the commands the app sends. Nothing here touches the network.
public enum GoStreamCommands {
    public static func setProgram(_ source: Int) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.pgmIndex, type: .set, value: [.number(Double(source))])
    }
    public static func setPreview(_ source: Int) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.pvwIndex, type: .set, value: [.number(Double(source))])
    }
    public static func cut() -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.cutTransition, type: .set)
    }
    public static func auto() -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.autoTransition, type: .set)
    }
    /// Style names as the switcher expects them: "Mix", "Dip" or "Wipe".
    public static func setTransitionStyle(_ name: String) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.transitionStyle, type: .set, value: [.string(name)])
    }
    public static func setMixRate(_ frames: Int) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.transitionMixRate, type: .set, value: [.number(Double(frames))])
    }
    public static func setStreamEnabled(_ stream: Int, _ on: Bool) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.liveStreamOutputEnable, type: .set,
                        value: [.number(Double(stream)), .number(on ? 1 : 0)])
    }
    /// Starts (true) or stops (false) the live stream.
    public static func live(_ on: Bool) -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.live, type: .set, value: [.number(on ? 1 : 0)])
    }
    /// Fade to black (no value). Not on every model.
    public static func ftb() -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.ftb, type: .set)
    }
    public static func startRecord() -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.recordStart, type: .set)
    }
    public static func stopRecord() -> GoStreamCommand {
        GoStreamCommand(id: GoStreamID.recordStop, type: .set)
    }
    public static func get(_ id: String, _ index: Int? = nil) -> GoStreamCommand {
        GoStreamCommand(id: id, type: .get, value: index.map { [.number(Double($0))] })
    }
}
