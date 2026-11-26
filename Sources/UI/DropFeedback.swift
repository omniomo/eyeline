import SwiftUI
import UniformTypeIdentifiers

// MARK: - 往窗口里拖文件
//
// 整个窗口哪里都能拖进来（稿子、幻灯片），什么时候都行。拖进窗口时盖一层提示：松开会怎样
// （导入 / 导入幻灯片 / 用这份幻灯片）。弄好了，底栏上面浮一句话（导入了什么、几页；正在转的话一直转圈）。

struct WindowDrop: DropDelegate {
    let model: AppModel

    static let slideTypes: [UTType] = [.pdf] + ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
                                                "com.apple.iwork.keynote.key"]
        .compactMap { UTType($0) }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let count = info.itemProviders(for: [.fileURL]).count
        model.dragEntered(count: count, slides: info.hasItemsConforming(to: WindowDrop.slideTypes))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.dragEnded()
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dragEnded()
        return FileDrop.load(info.itemProviders(for: [.fileURL])) { model.importFiles($0) }
    }
}

/// 拖着文件进窗口：窗口内缘一圈蓝边，底下一个短词说松开会怎样。不挡着后面的东西。
struct DropOverlay: View {
    let drag: AppModel.Drag

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Paper.blue.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Paper.blue, lineWidth: 2))
                .padding(5)
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Paper.blue))
            .shadow(color: Paper.blue.opacity(0.25), radius: 10, y: 4)
            .padding(.bottom, 92)
        }
        .allowsHitTesting(false)
    }

    private var symbol: String {
        switch drag {
        case .files: return "plus"
        case .slides, .attach: return "rectangle.on.rectangle"
        }
    }

    private var title: String {
        switch drag {
        case .files(let count) where count > 1: return String(localized: "Import \(count) files")
        case .files: return String(localized: "Import")
        case .slides: return String(localized: "Import slides")
        case .attach: return String(localized: "Use these slides")
        }
    }
}

/// 一句话提示：一小块玻璃，左边一个小图标；正在转的话是一个小菊花。
struct NoticeBanner: View {
    let notice: AppModel.Notice

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if notice.busy {
                    Spinner(size: 12, lineWidth: 1.8)
                } else {
                    Image(systemName: notice.problem ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(notice.problem ? Color(rgb: 0xD0574F) : Paper.gray)
                }
            }
            .frame(width: 16, height: 16)
            Text(notice.text)
                .font(.system(size: 13))
                .foregroundStyle(Paper.charcoal)
                .lineLimit(1)
        }
        .padding(.leading, 13)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .glass(cornerRadius: 18)
        .allowsHitTesting(false)
    }
}
