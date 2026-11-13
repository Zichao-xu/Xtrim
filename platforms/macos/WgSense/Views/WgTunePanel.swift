#if DEBUG
import AppKit
import SwiftUI

// 布局调节面板（仅 Debug / 预览版）：拖滑块实时改 WgTokens，满意后「保存到工程」。
// 打开：菜单「调试 → 布局调节…」（⌥⌘T），或启动参数 `-WgTunePanel YES`。

@MainActor
final class WgTunePanelController {
    static let shared = WgTunePanelController()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = String(localized: "布局调节", bundle: .wgLocalized)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: WgTunePanel())
            p.setFrameAutosaveName("WgTunePanel")
            if p.frame.origin == .zero { p.center() }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    static func showIfRequested() {
        guard UserDefaults.standard.bool(forKey: "WgTunePanel") else { return }
        DispatchQueue.main.async { shared.show() }
    }
}

struct WgTuneCommands: Commands {
    var body: some Commands {
        CommandMenu("调试") {
            Button("布局调节…") { WgTunePanelController.shared.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button(WgTokens.shared.guides ? "隐藏参考线" : "显示参考线") { WgTokens.shared.guides.toggle() }
                .keyboardShortcut("g", modifiers: [.command, .option])
        }
    }
}

struct WgTunePanel: View {
    @State private var group: WgTokenGroup = .space
    @State private var message: String?
    private var tokens: WgTokens { .shared }

    var body: some View {
        @Bindable var tokens = tokens
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $group) {
                    ForEach(WgTokenGroup.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("参考线（标出每块内边距的档位）", isOn: $tokens.guides)
                    .toggleStyle(.checkbox)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(group.specs) { row($0) }
                }
                .padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                Button("恢复默认") { tokens.resetToFallback() }
                Button("撤销改动") { tokens.revert() }
                    .disabled(!tokens.isDirty)
                Spacer()
                Button("保存到工程") {
                    message = tokens.saveToProject().map { String(localized: "保存失败：\($0)", bundle: .wgLocalized) } ?? String(localized: "已写入 WgTokens.json", bundle: .wgLocalized)
                }
                .keyboardShortcut("s")
                .disabled(!tokens.isDirty)
            }
            .padding(12)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    private func row(_ spec: WgTokenSpec) -> some View {
        let value = tokens[spec.key]
        let original = tokens.saved[spec.key] ?? spec.fallback
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.label).font(.system(.body, design: .monospaced))
                Spacer()
                if value != original {
                    Text("原 \(Self.format(original))").font(.caption).foregroundStyle(.secondary)
                }
                Text(Self.format(value))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: Binding(get: { value }, set: { tokens.set(spec.key, $0) }),
                        in: spec.range, step: group.step)
                    .labelsHidden()
            }
            Slider(value: Binding(get: { value }, set: { tokens.set(spec.key, ($0 / group.step).rounded() * group.step) }),
                   in: spec.range)
        }
    }

    private static func format(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
#endif
