import SwiftUI

@main
struct EyelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Eyeline", id: "main") {
            MainView(model: model, store: model.store)
                // 讲稿是一张白纸：侧栏也跟着用浅色（系统切到深色时两边才不会一黑一白）
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PromptCommands(model: model, prompter: model.prompter, prefs: model.prefs)
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Probe.runIfRequested() { return }
    }

    /// 关掉窗口不退出：提词条可能还开着。点 Dock 图标再打开窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.openMainWindow?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Probe.isRunning else { return }
        AppModel.shared.prompter.stop()
        AppModel.shared.recorder.close()
        AppModel.shared.store.save(now: true)
    }
}

struct PromptCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences

    var body: some Commands {
        // 设置、快捷键都在主窗口里浮起来（不另开窗口）
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.show(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Script") { model.newScript() }
                .keyboardShortcut("n")
            Button("Open…") { model.openFiles() }
                .keyboardShortcut("o")
            Button("Import from Keynote") { model.importFromKeynote() }
            Button("Attach Slides…") { model.chooseSlides() }
                .disabled(model.document == nil)
            Button("Remove Slides") { if let id = model.selection { model.removeSlides(id, undoManager: nil) } }
                .disabled(model.document?.slides == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Zoom In") { prefs.zoom(by: 1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { prefs.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { prefs.zoom(by: 0) }
                .keyboardShortcut("0")
        }
        CommandGroup(replacing: .help) {
            Button("Quick Start") { model.startQuickStart() }
            Button("Keyboard Shortcuts") { model.show(.shortcuts) }
                .keyboardShortcut("/")
        }
        CommandMenu("Prompt") {
            if prompter.isActive {
                Button("Stop") { model.play() }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Start from the Blue Dot") { model.play() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canPlay)
            }
            Button("Start from the Beginning") { model.play(fromBeginning: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(prompter.isActive || !model.canPlay)
            Divider()
            ForEach(Array(PromptMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle(mode.title, isOn: Binding(get: { (prompter.isActive ? prompter.activeMode : prefs.mode) == mode },
                                                 set: { if $0 { prompter.setMode(mode) } }))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            // 提词条上的字（⌘= ⌘- 留给主窗口的缩放）
            Button("Bigger") { prompter.changeSize(1) }
                .keyboardShortcut("=", modifiers: [.command, .option])
            Button("Smaller") { prompter.changeSize(-1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
        }
    }
}
