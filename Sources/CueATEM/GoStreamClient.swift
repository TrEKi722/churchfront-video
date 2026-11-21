import Foundation
import Network
import Combine

// TCP client for an OSEE GoStream (Deck, Duet). Default port 19010, no handshake,
// no keep-alive. We ask for state with `get`, then the switcher tells us about every
// change with `pus`. Not wired into the app yet; see GoStream.swift for the framing.

public struct GoStreamState: Equatable {
    /// Source numbers as the switcher reports them (see the module's sourceID enum).
    public var program: Int?
    public var preview: Int?
    public var inTransition = false
    public var transitionStyle = "Mix"
    public var mixRate: Int?
    /// Raw status values from the switcher. Their meaning is not confirmed on real
    /// hardware yet, so nothing interprets them.
    public var streamStatus: [Int: Int] = [:]
    public var recordStatus: Int?
    /// The device type number the switcher reports (0 Deck, 1 Duet SDI, 10 Duet 8 ISO, ...).
    public var deviceModel: Int?
    public var firmware: String?
    /// Source numbers the switcher says it has as inputs, from `inputList`.
    public var inputs: [Int] = []
    /// Fade to black: 0 off, 1 fully black, 2 fading.
    public var ftb: Int?

    public init() {}
}

public final class GoStreamClient: ObservableObject {
    public static let defaultPort: UInt16 = 19010

    @Published public private(set) var state = GoStreamState()
    @Published public private(set) var link: ATEMLink = .idle
    @Published public private(set) var host = ""
    /// Every command received or sent while debugging, newest last. Cleared by `connect`.
    @Published public private(set) var trace: [String] = []

    private let queue = DispatchQueue(label: "cuevideo.gostream")
    private var conn: NWConnection?
    private var decoder = GoStreamDecoder()

    public init() {}

    public func connect(host: String, port: UInt16 = GoStreamClient.defaultPort) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        self.host = host
        DispatchQueue.main.async { self.link = .connecting; self.trace = []; self.state = GoStreamState() }
        decoder = GoStreamDecoder()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection, self.conn === connection else { return }
            switch newState {
            case .ready:
                DispatchQueue.main.async { self.link = .online }
                self.receive(on: connection)
                self.requestState()
            case .failed(let error):
                DispatchQueue.main.async { self.link = .offline(error.localizedDescription) }
            case .waiting(let error):
                DispatchQueue.main.async { self.link = .offline(error.localizedDescription) }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async { self.link = .idle }
    }

    /// Sends commands in one write. Returns false if there is no connection.
    @discardableResult
    public func send(_ commands: [GoStreamCommand]) -> Bool {
        guard let conn, !commands.isEmpty else { return false }
        let bytes = GoStreamCodec.encodeAll(commands)
        record(commands.map { "→ \($0.type.rawValue) \($0.id) \(describe($0.value))" })
        conn.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { DispatchQueue.main.async { self?.link = .offline(error.localizedDescription) } }
        })
        return true
    }

    @discardableResult
    public func send(_ command: GoStreamCommand) -> Bool { send([command]) }

    /// Asks for everything we track. Replies arrive as `get` packets, changes as `pus`.
    public func requestState() {
        send([
            GoStreamCommands.get(GoStreamID.deviceType),
            GoStreamCommands.get(GoStreamID.version),
            GoStreamCommands.get(GoStreamID.inputList),
            GoStreamCommands.get(GoStreamID.ftbStatus),
            GoStreamCommands.get(GoStreamID.pgmIndex),
            GoStreamCommands.get(GoStreamID.pvwIndex),
            GoStreamCommands.get(GoStreamID.transitionStatus),
            GoStreamCommands.get(GoStreamID.transitionStyle),
            GoStreamCommands.get(GoStreamID.transitionMixRate),
            GoStreamCommands.get(GoStreamID.liveStreamOutputStatus, 0),
            GoStreamCommands.get(GoStreamID.recordStatus),
        ])
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.conn === connection else { return }
            if let data, !data.isEmpty {
                let commands = self.decoder.feed([UInt8](data))
                if !commands.isEmpty {
                    DispatchQueue.main.async {
                        self.record(commands.map { "← \($0.type.rawValue) \($0.id) \(self.describe($0.value))" })
                        for command in commands { self.apply(command) }
                    }
                }
            }
            if let error {
                DispatchQueue.main.async { self.link = .offline(error.localizedDescription) }
            } else if isComplete {
                DispatchQueue.main.async { self.link = .offline("Switcher closed the connection") }
            } else {
                self.receive(on: connection)
            }
        }
    }

    /// Updates state from a `get` reply or a `pus` push. Runs on the main thread.
    private func apply(_ command: GoStreamCommand) {
        guard command.type != .set else { return }
        let numbers = (command.value ?? []).compactMap { v -> Int? in
            if case .number(let n) = v { return Int(n) } else { return nil }
        }
        let first = (command.value ?? []).first
        var next = state
        switch command.id {
        case GoStreamID.pgmIndex: next.program = numbers.first
        case GoStreamID.pvwIndex: next.preview = numbers.first
        case GoStreamID.transitionStatus: next.inTransition = numbers.first == 1
        case GoStreamID.transitionStyle:
            if case .string(let s)? = first { next.transitionStyle = s }
        case GoStreamID.transitionMixRate: next.mixRate = numbers.first
        case GoStreamID.liveStreamOutputStatus:
            if numbers.count >= 2 { next.streamStatus[numbers[0]] = numbers[1] }
        case GoStreamID.recordStatus: next.recordStatus = numbers.first
        case GoStreamID.ftbStatus: next.ftb = numbers.first
        case GoStreamID.deviceType: next.deviceModel = numbers.first
        case GoStreamID.version:
            if case .string(let s)? = first { next.firmware = s }
        case GoStreamID.inputList:
            // Companion reads this as a list of source numbers, either as numbers or one "1,2,3,4" string.
            if case .string(let s)? = first {
                next.inputs = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else {
                next.inputs = numbers
            }
        default: break
        }
        if next != state { state = next }
    }

    private func describe(_ values: [GoStreamValue]?) -> String {
        (values ?? []).map { v -> String in
            switch v {
            case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
            case .string(let s): return "\"\(s)\""
            }
        }.joined(separator: ",")
    }

    private func record(_ lines: [String]) {
        let append = { [weak self] in
            guard let self else { return }
            self.trace.append(contentsOf: lines)
            if self.trace.count > 400 { self.trace.removeFirst(self.trace.count - 400) }
        }
        if Thread.isMainThread { append() } else { DispatchQueue.main.async(execute: append) }
    }
}
