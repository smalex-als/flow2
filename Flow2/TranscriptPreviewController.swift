import AppKit
import SwiftUI

enum TranscriptPreviewAction {
    case insert
    case discard
    case rewrite(RewriteStyle)
    case translate
}

@MainActor
final class TranscriptPreviewModel: ObservableObject {
    @Published var text: String
    @Published var isWorking = false
    @Published var note: String?

    var onAction: ((TranscriptPreviewAction) -> Void)?

    init(text: String = "") {
        self.text = text
    }
}

/// Shows what was heard and inserts nothing until asked.
///
/// The panel never takes focus, and that is not a detail. Taking it was the first thing tried, for
/// the sake of Enter and Escape, and it broke insertion: focus moving to Flow2 costs the target app
/// its caret, so the paste that followed had nowhere to land. Everything here is driven by the
/// mouse, and the field the user was typing in keeps the keyboard the whole time.
/// Stated once and read by both the panel and its content: the two used to carry their own copies
/// of the number, which is one edit away from a view that does not fill the window it sits in.
///
/// The width comes from measuring the button row rather than guessing at it — the four reshape
/// buttons and the two actions need 512pt, and at 460 their labels were being truncated.
private enum PreviewMetrics {
    static let size = CGSize(width: 600, height: 220)
}

@MainActor
final class TranscriptPreviewController {
    private static let size = PreviewMetrics.size

    private var panel: NSPanel?
    let model = TranscriptPreviewModel()

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Activation is asynchronous, so this is only meaningful a moment after the panel is shown —
    /// asked immediately it reports false whether or not the keyboard is on its way.
    var hasKeyboardFocus: Bool { panel?.isKeyWindow ?? false }

    /// Reports what the panel actually did, because "it did not appear" is otherwise indistinguishable
    /// from "it appeared blank", "it appeared off screen", and "it was never asked to appear".
    @discardableResult
    func show(text: String, near anchor: CGRect?, onAction: @escaping (TranscriptPreviewAction) -> Void) -> String {
        model.text = text
        model.isWorking = false
        model.note = nil
        model.onAction = onAction

        let panel = panel ?? makePanel()
        self.panel = panel

        // Set unconditionally: a window always comes with a content view of its own, so a check for
        // an empty one never fires and the panel opens transparent and blank.
        panel.contentView = NSHostingView(rootView: TranscriptPreviewView(model: model))

        position(panel, near: anchor)
        panel.orderFrontRegardless()

        let frame = panel.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        return "visible=\(panel.isVisible), frame=(\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width))x\(Int(frame.height))), onScreen=\(onScreen), hasContent=\(panel.contentView != nil)"
    }

    func hide() {
        model.onAction = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Just below the caret, so the panel is where the user is already looking.
    ///
    /// Accessibility reports screen coordinates with the origin at the top left, while windows are
    /// placed from the bottom left, so the anchor is flipped against the primary screen before use.
    /// Without an anchor the panel goes to the middle of whichever screen holds the pointer, rather
    /// than to the main screen — those are not the same display, and the difference is a panel the
    /// user has to go looking for.
    private func position(_ panel: NSPanel, near anchor: CGRect?) {
        guard let primary = NSScreen.screens.first else { return }

        guard let anchor else {
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? primary
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - Self.size.width / 2,
                                         y: screen.visibleFrame.midY - Self.size.height / 2))
            return
        }

        let flippedBottom = primary.frame.maxY - anchor.maxY
        var origin = CGPoint(x: anchor.minX, y: flippedBottom - Self.size.height - 10)

        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: flippedBottom)) } ?? primary
        let visible = screen.visibleFrame

        // A caret near the bottom of the screen would put the panel off it, so it flips above.
        if origin.y < visible.minY {
            origin.y = primary.frame.maxY - anchor.minY + 10
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)

        panel.setFrameOrigin(origin)
    }
}

private struct TranscriptPreviewView: View {
    @ObservedObject var model: TranscriptPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                Text(model.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(model.isWorking ? 0.45 : 1)

            controls
        }
        .padding(16)
        .frame(width: PreviewMetrics.size.width, height: PreviewMetrics.size.height)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Smart Dictate", systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if let note = model.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            reshapeButton("Shorter", systemImage: "arrow.down.right.and.arrow.up.left", action: .rewrite(.shorter))
            reshapeButton("Longer", systemImage: "arrow.up.left.and.arrow.down.right", action: .rewrite(.longer))
            reshapeButton("Formal", systemImage: "briefcase", action: .rewrite(.professional))
            reshapeButton("Translate", systemImage: "globe", action: .translate)

            Spacer(minLength: 0)

            // Without keyboard focus there is no Escape, so dismissing has to be clickable too.
            Button("Discard") {
                model.onAction?(.discard)
            }
            .disabled(model.isWorking)

            Button("Insert") {
                model.onAction?(.insert)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
        }
    }

    private func reshapeButton(_ title: String, systemImage: String, action: TranscriptPreviewAction) -> some View {
        Button {
            model.onAction?(action)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .disabled(model.isWorking)
    }
}
