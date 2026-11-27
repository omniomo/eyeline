import SwiftUI

// MARK: - 画面：录什么
//
// 底栏上一个按钮（现在录什么的图标）；点开是一块玻璃：几张小画——人像 / 屏幕 / 屏幕 + 人像 / 不录制，
// 按播放不再问，直接照这里录；选过的会记住。默认「屏幕 + 人像」，横屏。
// 录屏幕时：录整块屏幕（设置里可以改成放映时只录幻灯片）；圆框人像是屏幕上的一个圆，拖到哪录到哪（见 CameraBubble）。

extension RecordLayout {
    var title: String {
        switch self {
        case .camera: return String(localized: "Camera")
        case .screen: return String(localized: "Screen")
        case .both: return String(localized: "Screen + camera")
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "video"
        case .screen: return "macwindow"
        case .both: return "rectangle.inset.bottomright.filled"
        }
    }
}

/// 底栏上的按钮：现在录什么的图标，鼠标停上去冒出名字，点一下打开面板。提词时不能改。
struct ShotButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences
    let disabled: Bool
    @State private var hovering = false
    @State private var tip = false
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        let shot = model.shot
        let title = shot?.title ?? String(localized: "Don't record")
        Button {
            withAnimation(.omoOut(0.28)) { model.showingShots.toggle() }
        } label: {
            Image(systemName: shot?.symbol ?? "video.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.showingShots ? Paper.accent
                                 : shot == nil ? (hovering ? Paper.gray : Paper.fog)
                                 : (hovering ? Paper.ink : Paper.charcoal))
                .symbolReplaceTransition()
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { inside in
            hovering = inside && !disabled
            tipTask?.cancel()
            if inside {
                tipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled { tip = true }
                }
            } else {
                tip = false
            }
        }
        .overlay(alignment: .top) {
            if tip && !model.showingShots {
                HoverTip(text: title)
                    .fixedSize()
                    .offset(y: -38)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.omoOut(0.18), value: tip)
        .accessibilityLabel(title)
    }
}

/// 打开的面板：四张小画并排，点一张就收起。（放映时录整块屏幕还是只录幻灯片，在设置 › 录制里。）
struct ShotPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences
    let close: () -> Void

    var body: some View {
        let shot = model.shot
        let options: [RecordLayout?] = [.camera, .screen, .both, nil]
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { item in
                ShotCard(layout: item, selected: item == shot) {
                    withAnimation(.omoOut(0.3)) { model.setShot(item) }
                    close()
                }
            }
        }
        .padding(8)
        .glass(cornerRadius: 22)
        .fixedSize()
    }
}

private struct ShotCard: View {
    let layout: RecordLayout?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let title = layout?.title ?? String(localized: "Don't record")
        Button(action: action) {
            VStack(spacing: 9) {
                ShotArt(layout: layout)
                    .frame(width: 124, height: 80)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.85)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Paper.blue.opacity(0.8) : Color.black.opacity(0.06), lineWidth: selected ? 2 : 0.5)
                    )
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Paper.ink : Paper.charcoal)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(hovering && !selected ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一张小画：录出来的样子（横屏），屏幕、人各在哪。
struct ShotArt: View {
    let layout: RecordLayout?

    var body: some View {
        let size = CGSize(width: 104, height: 58)
        if let layout {
            content(layout, size)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        } else {
            Image(systemName: "video.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Paper.fog)
        }
    }

    @ViewBuilder private func content(_ layout: RecordLayout, _ size: CGSize) -> some View {
        switch layout {
        case .camera:
            MiniPerson()
        case .screen:
            MiniScreen()
        case .both:
            let d = (size.height * 0.42).rounded()
            ZStack(alignment: .bottomTrailing) {
                MiniScreen()
                MiniPerson()
                    .frame(width: d, height: d)
                    .clipShape(Circle())
                    .padding(1.2)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .padding(size.height * 0.08)
            }
        }
    }
}

/// 小画里的屏幕：顶上一条菜单栏，中间一个窗口（三个小圆点、几行字）。
private struct MiniScreen: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack(alignment: .topLeading) {
                Color(rgb: 0xEEF1F6)
                Rectangle().fill(Color.white.opacity(0.75)).frame(width: w, height: max(2, h * 0.07))
                VStack(alignment: .leading, spacing: h * 0.07) {
                    HStack(spacing: max(1, w * 0.012)) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Paper.fog.opacity(0.7)).frame(width: max(1.5, w * 0.022), height: max(1.5, w * 0.022))
                        }
                    }
                    Capsule().fill(Paper.ink.opacity(0.7)).frame(width: w * 0.3, height: max(1.5, h * 0.07))
                    Capsule().fill(Paper.fog.opacity(0.6)).frame(width: w * 0.42, height: max(1.2, h * 0.045))
                    Capsule().fill(Paper.fog.opacity(0.6)).frame(width: w * 0.34, height: max(1.2, h * 0.045))
                }
                .padding(.leading, w * 0.06)
                .padding(.top, h * 0.07)
                .frame(width: w * 0.78, height: h * 0.7, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: max(1, w * 0.025), style: .continuous).fill(.white)
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5))
                .offset(x: w * 0.11, y: h * 0.18)
            }
        }
    }
}

/// 小画里的人：一块柔和的底色，一个头和肩膀。
private struct MiniPerson: View {
    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(rgb: 0xD6E5F5), Color(rgb: 0xF3E1D4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: s * 0.05) {
                    Circle().frame(width: s * 0.3, height: s * 0.3)
                    UnevenRoundedRectangle(topLeadingRadius: s * 0.3, topTrailingRadius: s * 0.3, style: .continuous)
                        .frame(width: s * 0.64, height: s * 0.24)
                }
                .foregroundStyle(Color.white.opacity(0.94))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// 打开的画面面板：浮在按钮上面（右边和按钮差不多对齐），点外面收起。
struct ShotsOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences
    let anchor: Anchor<CGRect>

    var body: some View {
        GeometryReader { geometry in
            let rect = geometry[anchor]
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .shieldsTextCursor("shots")
                ShotPanel(model: model, prefs: prefs, close: close)
                    .frame(width: min(geometry.size.width - 8, max(rect.maxX + 110, 600)),
                           height: max(0, rect.minY - 10), alignment: .bottomTrailing)
                    .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
    }

    private func close() {
        withAnimation(.omoOut(0.22)) { model.showingShots = false }
    }
}
