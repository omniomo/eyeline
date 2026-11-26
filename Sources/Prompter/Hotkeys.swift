import AppKit
import Carbon.HIToolbox

// MARK: - 全局快捷键
//
// 只在提词的时候注册，结束就还给别的 App。用的是 Carbon 的 RegisterEventHotKey，
// 不需要「辅助功能」权限。翻页笔和脚踏板发的是 PageUp / PageDown，也一起接住。

enum HotkeyAction: UInt32, CaseIterable {
    case pause = 1, back, forward, faster, slower, bigger, smaller, stop, clickerBack, clickerForward

    var keyCode: Int {
        switch self {
        case .pause: return kVK_Space
        case .back: return kVK_LeftArrow
        case .forward: return kVK_RightArrow
        case .faster: return kVK_UpArrow
        case .slower: return kVK_DownArrow
        case .bigger: return kVK_ANSI_Equal
        case .smaller: return kVK_ANSI_Minus
        case .stop: return kVK_Escape
        case .clickerBack: return kVK_PageUp
        case .clickerForward: return kVK_PageDown
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .clickerBack, .clickerForward: return 0
        default: return UInt32(optionKey)
        }
    }

    /// 显示给人看的写法。
    var symbol: String {
        switch self {
        case .pause: return "⌥ Space"
        case .back: return "⌥ ←"
        case .forward: return "⌥ →"
        case .faster: return "⌥ ↑"
        case .slower: return "⌥ ↓"
        case .bigger: return "⌥ ="
        case .smaller: return "⌥ −"
        case .stop: return "⌥ Esc"
        case .clickerBack: return "Page Up"
        case .clickerForward: return "Page Down"
        }
    }
}

final class Hotkeys {
    static let shared = Hotkeys()
    var handler: ((HotkeyAction) -> Void)?

    private var registered: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    var isEnabled: Bool { !registered.isEmpty }

    /// clicker：要不要接住翻页笔（PageUp / PageDown）。跟着 Keynote 翻页时留给 Keynote。
    func enable(clicker: Bool = true) {
        guard registered.isEmpty else { return }
        installHandler()
        for action in HotkeyAction.allCases where clicker || (action != .clickerBack && action != .clickerForward) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4559_4C4E), id: action.rawValue)   // 'EYLN'
            let status = RegisterEventHotKey(UInt32(action.keyCode), action.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered.append(ref) }
        }
    }

    func disable() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr, let action = HotkeyAction(rawValue: id.id) {
                DispatchQueue.main.async { Hotkeys.shared.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
