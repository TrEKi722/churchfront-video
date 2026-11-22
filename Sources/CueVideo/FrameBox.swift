import SwiftUI

/// The "dead box" for one shot size: the eyes are held at its centre, and the camera only moves once they
/// leave it. All measured across the picture (0 to 1 from the left) and down it (0 to 1 from the top).
struct FrameBox: Equatable {
    var markX: Double, eyeLine: Double, deadX: Double, deadY: Double

    /// Keeps the box on the picture and a usable size.
    var clamped: FrameBox {
        FrameBox(markX: min(0.9, max(0.1, markX)), eyeLine: min(0.6, max(0.08, eyeLine)),
                 deadX: min(0.3, max(0.02, deadX)), deadY: min(0.25, max(0.02, deadY)))
    }

    init(markX: Double, eyeLine: Double, deadX: Double, deadY: Double) {
        self.markX = markX; self.eyeLine = eyeLine; self.deadX = deadX; self.deadY = deadY
    }

    /// The box in use for a shot size: the standard with any changes from the setup file.
    init(_ size: ShotSize, _ config: CueConfig) {
        let r = size.standard.merged(config.framing[size.rawValue])
        self.init(markX: min(0.9, max(0.1, r.markX ?? 0.5)), eyeLine: r.eyeLine ?? 0.3, deadX: r.deadX ?? 0.07, deadY: r.deadY ?? 0.08)
    }
}

/// Drawn over the Next picture while "Frame box" is on: the dead box, which can be dragged to where the
/// person should sit in the shot (the left or right of the picture, higher or lower), and resized from its
/// corners and sides. It is saved for the shot size being edited, and takes effect as you let go.
struct FrameBoxEditor: View {
    let size: ShotSize
    /// Where the picture sits inside the view this is drawn in.
    let picture: CGRect
    @EnvironmentObject var store: ConfigStore
    @State private var live: FrameBox?
    @State private var begin: FrameBox?

    private enum Grab { case move, corner, sideX, sideY }

    private var saved: FrameBox { FrameBox(size, store.config) }

    var body: some View {
        let b = live ?? saved
        let w = picture.width, h = picture.height
        let box = CGRect(x: picture.minX + (b.markX - b.deadX) * w, y: picture.minY + (b.eyeLine - b.deadY) * h,
                         width: b.deadX * 2 * w, height: b.deadY * 2 * h)
        let eye = CGPoint(x: picture.minX + b.markX * w, y: picture.minY + b.eyeLine * h)
        ZStack {
            // The box itself: drag it to move where the eyes are held.
            Rectangle().fill(T.accent.opacity(0.14))
                .overlay(Rectangle().stroke(T.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 4])))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .gesture(drag(.move))
            // Where the eyes are held.
            Group {
                Rectangle().fill(T.accent).frame(width: 18, height: 1.5)
                Rectangle().fill(T.accent).frame(width: 1.5, height: 18)
            }
            .position(x: eye.x, y: eye.y).allowsHitTesting(false)
            Text("EYES HERE").font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(T.accent)
                .shadow(color: .black, radius: 2).position(x: eye.x, y: eye.y + 14).allowsHitTesting(false)
            // Corners resize both ways, sides one way. The box stays centred on the eyes.
            handle(box.minX, box.minY, .corner); handle(box.maxX, box.minY, .corner)
            handle(box.minX, box.maxY, .corner); handle(box.maxX, box.maxY, .corner)
            handle(box.minX, box.midY, .sideX); handle(box.maxX, box.midY, .sideX)
            handle(box.midX, box.minY, .sideY); handle(box.midX, box.maxY, .sideY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ x: CGFloat, _ y: CGFloat, _ grab: Grab) -> some View {
        ZStack { RoundedRectangle(cornerRadius: 3).fill(T.accent).frame(width: 11, height: 11)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.7))) }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .gesture(drag(grab))
    }

    private func drag(_ grab: Grab) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pic"))
            .onChanged { v in
                let start = begin ?? saved
                if begin == nil { begin = start }
                var b = start
                let nx = (v.location.x - picture.minX) / max(1, picture.width)
                let ny = (v.location.y - picture.minY) / max(1, picture.height)
                switch grab {
                case .move:
                    b.markX = start.markX + v.translation.width / max(1, picture.width)
                    b.eyeLine = start.eyeLine + v.translation.height / max(1, picture.height)
                case .corner:
                    b.deadX = abs(nx - start.markX); b.deadY = abs(ny - start.eyeLine)
                case .sideX: b.deadX = abs(nx - start.markX)
                case .sideY: b.deadY = abs(ny - start.eyeLine)
                }
                live = b.clamped
            }
            .onEnded { _ in
                if let b = live { commit(b) }
                live = nil; begin = nil
            }
    }

    private func commit(_ b: FrameBox) {
        let z = size
        store.update { c in
            var r = c.framing[z.rawValue] ?? FramingRule()
            r.markX = b.markX; r.eyeLine = b.eyeLine; r.deadX = b.deadX; r.deadY = b.deadY
            c.framing[z.rawValue] = r
        }
    }
}

/// Under the Track button: turns the dead box on the Next picture on and off, picks the shot size it is
/// for when the camera isn't tracking, sets lead room, and shows the numbers.
struct FrameBoxControls: View {
    let camera: PTZCamera
    /// The size being followed, when this camera is tracking.
    let tracking: ShotSize?
    @ObservedObject private var tracker = AutoTracker.shared
    @EnvironmentObject var store: ConfigStore

    private var editing: Bool { tracker.editingCamera == camera.id }
    private var size: ShotSize { tracking ?? tracker.editSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { tracker.editingCamera = editing ? nil : camera.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 12, weight: .bold))
                    LabelText(editing ? "Done" : "Frame box", size: 11)
                }
                .foregroundStyle(editing ? T.onAction : T.ink)
                .frame(maxWidth: .infinity).frame(height: 26)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(editing ? T.accent : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(editing ? T.accent : T.lineStrong))
            }
            .buttonStyle(PressStyle())
            .disabled(CameraPicture.of(camera, store) == nil)
            .help("Show the dead box on the Next picture. Drag it to where the person should sit in the shot, and drag its corners and sides to change how far they can drift before the camera moves.")
            if editing {
                if tracking == nil {
                    HStack(spacing: 2) {
                        ForEach(ShotSize.allCases) { z in
                            Button { tracker.editSize = z } label: {
                                Text(z.short).font(.sans(11, .semibold))
                                    .foregroundStyle(size == z ? T.onAction : T.inkMuted)
                                    .frame(maxWidth: .infinity).frame(height: 22)
                                    .background(RoundedRectangle(cornerRadius: T.rSM).fill(size == z ? T.accent : T.surfaceSunken))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                let b = FrameBox(size, store.config)
                Text("\(size.name): ±\(pct(b.deadX)) wide, ±\(pct(b.deadY)) tall, centre \(pct(b.markX)) across, eyes \(pct(b.eyeLine)) down")
                    .font(.sans(10)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Lead room").font(.sans(11)).foregroundStyle(T.inkMuted)
                    Slider(value: Binding(get: { size.leadRoom }, set: { v in setLead(v) }), in: 0...0.2)
                        .controlSize(.mini)
                }
                .help("How far the box shifts toward the way they face or walk. Zero keeps it exactly where you put it.")
                Button("Reset this shot") { store.update { $0.framing[size.rawValue] = nil } }
                    .buttonStyle(.plain).font(.sans(11)).foregroundStyle(T.inkMuted)
            }
        }
        .onDisappear { if tracker.editingCamera == camera.id { tracker.editingCamera = nil } }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func setLead(_ v: Double) {
        let z = size
        store.update { c in
            var r = c.framing[z.rawValue] ?? FramingRule()
            r.leadRoom = v
            c.framing[z.rawValue] = r
        }
    }
}
