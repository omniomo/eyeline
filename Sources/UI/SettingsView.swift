import SwiftUI

/// 设置：自己画的开关、分段、下拉（不用系统的表单），四块白卡片：通用、提词条、朗读、录制。
struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    var openShortcuts: () -> Void = {}
    var onRibbonChange: () -> Void = {}
    @State private var appLanguage = AppLanguage.current
    /// 换了界面语言：重新打开才生效。
    @State private var languageChanged = false
    /// 识别语言的下拉开着。
    @State private var languageMenu = false
    /// 登录时打开：读系统里的真实状态（默认没加进登录项）。
    @State private var openAtLogin = LoginItem.isOn

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: nil) {
                SettingsRow(String(localized: "Interface language")) {
                    Segmented(selection: $appLanguage, options: [
                        (AppLanguage.system, String(localized: "Follow System")),
                        (AppLanguage.english, "English"),
                        (AppLanguage.chinese, "简体中文"),
                    ])
                }
                if languageChanged {
                    SettingsRow(String(localized: "Takes effect after Eyeline reopens"), secondary: true) {
                        PillButton(title: String(localized: "Reopen Now")) { AppLanguage.relaunch() }
                    }
                }
                SettingsRow(String(localized: "Open at login")) {
                    Switch(isOn: $openAtLogin)
                }
                SettingsRow(String(localized: "Keyboard shortcuts"), last: true) {
                    PillButton(title: String(localized: "Show")) { openShortcuts() }
                }
            }

            SettingsSection(title: String(localized: "Ribbon")) {
                SettingsRow(String(localized: "Size")) {
                    Segmented(selection: $prefs.size, options: (0..<Preferences.sizeSteps).map { ($0, ["S", "M", "L", "XL", "XXL"][$0]) })
                }
                SettingsRow(String(localized: "Display")) {
                    Segmented(selection: $prefs.display, options: [
                        (RibbonDisplay.builtIn, String(localized: "The one with the camera")),
                        (RibbonDisplay.main, String(localized: "Main screen")),
                    ])
                }
                SettingsRow(String(localized: "Hide from screen recording"), last: true) {
                    Switch(isOn: $prefs.hideFromCapture)
                }
            }

            SettingsSection(title: String(localized: "Reading")) {
                SettingsRow(String(localized: "Speech language")) {
                    Dropdown(selection: $prefs.language, options: [
                        (SpeechLanguage.automatic, String(localized: "Automatic")),
                        (SpeechLanguage.mandarin, String(localized: "Mandarin (Simplified)")),
                        (SpeechLanguage.taiwanese, String(localized: "Mandarin (Traditional)")),
                        (SpeechLanguage.cantonese, String(localized: "Cantonese")),
                        (SpeechLanguage.english, String(localized: "English")),
                        (SpeechLanguage.japanese, String(localized: "Japanese")),
                    ], open: $languageMenu)
                }
                .zIndex(1)
                SettingsRow(String(localized: "Turn slides automatically")) {
                    Switch(isOn: $prefs.autoTurnSlides)
                }
                SettingsRow(String(localized: "Count down before a steady scroll")) {
                    Switch(isOn: $prefs.countdown)
                }
                SettingsRow(String(localized: "Hold for a moment at ⏸")) {
                    Switch(isOn: $prefs.holdAtPauses)
                }
                SettingsRow(String(localized: "Skip lines marked ✂"), last: true) {
                    Switch(isOn: $prefs.skipCuts)
                }
            }
            .zIndex(1)

            SettingsSection(title: String(localized: "Recording")) {
                SettingsRow(String(localized: "Record only the slide while presenting"), last: true) {
                    Switch(isOn: $prefs.recordSlideOnly)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // 下拉开着：点空白处收起
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { if languageMenu { withAnimation(.omoOut(0.2)) { languageMenu = false } } }
        }
        .onChangeOf(openAtLogin) { _, on in
            guard on != LoginItem.isOn else { return }
            LoginItem.set(on)
            openAtLogin = LoginItem.isOn
        }
        .onChangeOf(appLanguage) { _, language in
            language.apply()
            withAnimation(.omoOut(0.25)) { languageChanged = language != AppLanguage.launched }
        }
        .onChangeOf(prefs.size) { _, _ in onRibbonChange() }
        .onChangeOf(prefs.display) { _, _ in onRibbonChange() }
        .onChangeOf(prefs.hideFromCapture) { _, _ in onRibbonChange() }
        .preferredColorScheme(.light)
    }
}

/// 设置里的一块：上面一行小标题，下面一张白卡片。
private struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Paper.gray)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
        }
    }
}

/// 卡片里的一行：左边名字，右边控件，行与行之间一条细线。
private struct SettingsRow<Control: View>: View {
    let title: String
    var secondary = false
    var last = false
    @ViewBuilder let control: Control

    init(_ title: String, secondary: Bool = false, last: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.secondary = secondary
        self.last = last
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(secondary ? Paper.gray : Paper.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Paper.line).frame(height: 0.5) }
        }
    }
}

/// 界面用什么语言：跟系统，或者固定英文 / 简体中文（写进这个 app 自己的 AppleLanguages，重新打开生效）。
enum AppLanguage: String, Hashable {
    case system, english = "en", chinese = "zh-Hans"

    /// 设置里现在选的。
    static var current: AppLanguage {
        guard let codes = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = codes.first else { return .system }
        return first.hasPrefix("zh") ? .chinese : first.hasPrefix("en") ? .english : .system
    }

    /// 这次打开时用的（换了以后要重新打开）。
    static let launched = AppLanguage.current

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 快捷键一览（帮助 › 快捷键，⌘/）

struct ShortcutsView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let keys: [String]
        let text: String
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    private var left: [Group] {
        [
            Group(title: String(localized: "Scripts"), rows: [
                Row(keys: ["⌘", "N"], text: String(localized: "New Script")),
                Row(keys: ["⌘", "O"], text: String(localized: "Open…")),
                Row(keys: ["⌘", "="], text: String(localized: "Zoom In")),
                Row(keys: ["⌘", "-"], text: String(localized: "Zoom Out")),
                Row(keys: ["⌘", "0"], text: String(localized: "Actual Size")),
                Row(keys: ["⌘", ","], text: String(localized: "Settings")),
            ]),
            Group(title: String(localized: "Slides"), rows: [
                Row(keys: ["↑", "↓"], text: String(localized: "Previous, next slide's lines")),
                Row(keys: ["Tab"], text: String(localized: "Next slide's lines")),
                Row(keys: ["↩"], text: String(localized: "On an empty line: next slide")),
            ]),
        ]
    }

    private var right: [Group] {
        [
            Group(title: String(localized: "Start"), rows: [
                Row(keys: ["⌘", "↩"], text: String(localized: "Start or stop")),
                Row(keys: ["⇧", "⌘", "↩"], text: String(localized: "Start from the top")),
                Row(keys: ["⌘", "1–4"], text: String(localized: "How the words move")),
                Row(keys: ["⌥", "⌘", "="], text: String(localized: "Bigger ribbon text")),
                Row(keys: ["⌥", "⌘", "-"], text: String(localized: "Smaller ribbon text")),
            ]),
            Group(title: String(localized: "While prompting"), rows: [
                Row(keys: ["Space"], text: String(localized: "Pause or resume")),
                Row(keys: ["←", "→"], text: String(localized: "Back, next (line or slide)")),
                Row(keys: ["↑", "↓"], text: String(localized: "Faster, slower")),
                Row(keys: ["Esc"], text: String(localized: "Stop")),
                Row(keys: ["Page Up", "Page Down"], text: String(localized: "Clicker")),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 40) {
                column(left)
                column(right)
            }
            Text("In other apps, add ⌥ to the keys above (⌥ Space, ⌥ ←, ⌥ Esc…)")
                .font(.system(size: 12))
                .foregroundStyle(Paper.gray)
        }
        .padding(28)
        .fixedSize()
    }

    private func column(_ groups: [Group]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Paper.gray)
                    ForEach(group.rows) { row in
                        HStack(spacing: 16) {
                            Text(row.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Paper.ink)
                            Spacer(minLength: 12)
                            HStack(spacing: 3) {
                                ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in KeyCap(key: key) }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 330, alignment: .leading)
    }
}

/// 一个键帽。
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(Paper.charcoal)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 21)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Paper.haze))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Paper.line, lineWidth: 0.5))
    }
}
