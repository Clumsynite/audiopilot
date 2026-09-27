import AppKit
import Carbon
import AudioPilotCore
import SwiftUI

/// Click, then press a key combination. Esc cancels. Callers unregister the matching global hotkey
/// in `onBegin` so the current combination reaches the recorder.
struct HotKeyRecorder: View {
    var current: HotKeySpec?
    var onBegin: () -> Void
    var onCancel: () -> Void
    var onRecord: (HotKeySpec) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop(cancelled: true) : start()
        } label: {
            Text(title)
                .foregroundStyle(current == nil && !recording ? .secondary : .primary)
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .help("Click, then press the new shortcut. Esc cancels.")
        .onDisappear { if recording { stop(cancelled: true) } }
    }

    private var title: String {
        if recording { return "Type shortcut…" }
        return current.map(KeyNames.string) ?? "Record Shortcut"
    }

    private func start() {
        recording = true
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop(cancelled: true)
            return
        }
        let mods = KeyNames.carbonModifiers(event.modifierFlags)
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            NSSound.beep()
            return
        }
        stop(cancelled: false)
        onRecord(HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods))
    }

    private func stop(cancelled: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if cancelled { onCancel() }
    }
}
