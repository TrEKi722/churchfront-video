import Foundation

// Turns a GoStream's state into the ATEMState the app already understands, so the
// screens and Claude's tools work unchanged. A GoStream has one mix bus (reported as
// M/E 1) and no aux outputs, keyers, DSKs or macros, so those stay empty and the app
// hides what it can't use.

extension ATEMState {
    init(goStream g: GoStreamState) {
        self.init()
        product = Self.goStreamProduct(g)
        version = g.firmware ?? ""

        // Wait for the first program reply, so the app doesn't treat an empty switcher as ready.
        guard let programValue = g.program else { return }

        // The app counts inputs from 1. Firmware before 2.3 counts from 0 (see sourceOffset).
        let offset = g.sourceOffset
        func app(_ deviceSource: Int) -> Int { deviceSource + offset }

        // Firmware 2.1.4 has no inputList; a Deck has four inputs.
        let sources = (g.inputs.isEmpty ? [1, 2, 3, 4] : g.inputs.map(app)).filter { (1...999).contains($0) }
        for id in sources {
            inputs[id] = ATEMInput(id: id, long: "Input \(id)", short: "IN\(id)")
        }

        program[0] = app(programValue)
        if let previewValue = g.preview { preview[0] = app(previewValue) }
        inTransition[0] = g.inTransition
        nextSelection[0] = 1 // background only; there are no keys to add
        switch g.transitionStyle {
        case "Dip": style[0] = 1
        case "Wipe": style[0] = 2
        default: style[0] = 0
        }
        if let rate = g.mixRate { mixRate[0] = rate }

        ftbBlack[0] = g.ftb == 1
        ftbInTransition[0] = g.ftb == 2

        // Streaming: `live` (1 = on) on firmware 2.1.4, or the per-output status (1 = on) on newer firmware.
        // The app reads bit 2 (value 4) as streaming.
        hasStreaming = g.live != nil || !g.streamStatus.isEmpty
        streamStatus = (g.live == 1 || g.streamStatus.values.contains(1)) ? 4 : 0

        // Record: only the value 1 is treated as recording. Firmware 2.1.4 has no recordStatus,
        // so there's no Record button until we know its command.
        hasRecording = g.recordStatus != nil
        recordStatus = g.recordStatus == 1 ? 1 : 0

        tally[program[0] ?? 0, default: 0] |= 1
        if let p = preview[0] { tally[p, default: 0] |= 2 }
    }

    private static func goStreamProduct(_ g: GoStreamState) -> String {
        if let name = g.deviceName, !name.isEmpty { return "\(name) (GoStream)" }
        switch g.deviceModel {
        case 0?: return "GoStream Deck"
        case 1?: return "GoStream Duet SDI"
        case 2?, 3?: return "GoStream Deck"
        case 10?: return "GoStream Duet 8 ISO"
        default: return "GoStream"
        }
    }
}
