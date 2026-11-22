import SwiftUI

/// Setup > Switcher: turns the iPad and web control on, and shows where to point the iPad and the PIN.
struct WebControlCard: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var web = WebServer.shared

    private var urls: [String] {
        var out: [String] = []
        let name = ProcessInfo.processInfo.hostName
        if !name.isEmpty { out.append("http://\(name):\(WebServer.port)") }
        out += WebServer.addresses().map { "http://\($0):\(WebServer.port)" }
        return out
    }

    var body: some View {
        Card(title: "iPad and web control",
             help: "Opens a page on this Mac that an iPad, phone or other computer on the same network can use to run the booth: Next and Live pictures, the source row, Cut, Fade, Black, the camera joystick, shots and Track. It asks for the PIN below. Anyone on this network who has the PIN can cut, fade and move cameras, so use it on a network you trust. It uses plain HTTP, and a firewall prompt may ask to allow incoming connections.") {
            HStack(spacing: T.s3) {
                Text("Let other devices run the booth").font(.sans(13))
                Toggle("", isOn: Binding(get: { store.config.webControl }, set: { v in store.update { $0.webControl = v } }))
                    .labelsHidden().toggleStyle(.switch)
                Spacer(minLength: 0)
            }
            if store.config.webControl {
                if let p = web.problem {
                    Text(p).font(.sans(12)).foregroundStyle(T.danger)
                }
                HStack(alignment: .top, spacing: T.s3) {
                    Text("Open on the iPad").font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(urls, id: \.self) { Text($0).font(.system(size: 13, design: .monospaced)).textSelection(.enabled) }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: T.s3) {
                    Text("PIN").font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
                    Text(web.pin).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Button("New PIN") { web.newPIN() }.buttonStyle(CueButton())
                    Text(web.running ? "Running" : "Starting").font(.sans(12)).foregroundStyle(web.running ? T.inkMuted : T.warning)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
