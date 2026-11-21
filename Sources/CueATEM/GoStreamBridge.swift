import Foundation

// Turns a GoStream's state into the ATEMState the app already understands, so the
// screens and Claude's tools work unchanged. A GoStream has one mix bus (reported as
// M/E 1) and no aux outputs, keyers, DSKs or macros, so those stay empty and the app
// hides what it can't use.

extension ATEMState {
    init(goStream g: GoStreamState) {
        self.init()
        product = Self.goStreamProduct(g.deviceModel)
        version = g.firmware ?? ""

        // Wait for the first program reply, so the app doesn't treat an empty switcher as ready.
        guard g.program != nil else { return }

        let sources = (g.inputs.isEmpty ? [1, 2, 3, 4] : g.inputs).filter { (1...999).contains($0) }
        for id in sources {
            inputs[id] = ATEMInput(id: id, long: "Input \(id)", short: "IN\(id)")
        }

        if let program = g.program { self.program[0] = program }
        if let preview = g.preview { self.preview[0] = preview }
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

        // Stream: 1 is on (the module's LiveStatus). The app reads bit 2 (value 4) as streaming.
        hasStreaming = !g.streamStatus.isEmpty
        streamStatus = g.streamStatus.values.contains(1) ? 4 : 0

        // Record: only the value 1 is treated as recording. Other values are unconfirmed on real hardware.
        hasRecording = g.recordStatus != nil
        recordStatus = g.recordStatus == 1 ? 1 : 0

        if let program = g.program { tally[program, default: 0] |= 1 }
        if let preview = g.preview { tally[preview, default: 0] |= 2 }
    }

    private static func goStreamProduct(_ model: Int?) -> String {
        switch model {
        case 0?: return "GoStream Deck"
        case 1?: return "GoStream Duet SDI"
        case 2?, 3?: return "GoStream Deck"
        case 10?: return "GoStream Duet 8 ISO"
        default: return "GoStream"
        }
    }
}
