import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profile 管理入口

struct ProfileManagerView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var showImport = false
    @State private var showWizard = false
    @State private var showExport = false
    @State private var exportProfile: String?
    @State private var showDeleteConfirm = false
    @State private var deleteProfile: String?
    @State private var editProfile: ProfileName?

// Wrapper for sheet(item:)
struct ProfileName: Identifiable {
    let name: String
    var id: String { name }
}

    var body: some View {
        WgPage(title: "配置", subtitle: "WireGuard 隧道配置，当前使用的会标记为「使用中」", word: "PROFILES") {
            HStack(spacing: WgSpace.s) {
                Button { showImport = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
                    .buttonStyle(WgPillButtonStyle())
                Button { showWizard = true } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
            }
        } content: {
            if client.profiles.isEmpty {
                emptyState
            } else {
                WgSection(title: nil) {
                    ForEach(client.profiles, id: \.self) { p in
                        profileRow(p)
                        if p != client.profiles.last { WgRowDivider() }
                    }
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportConfView { name, content in
                Task {
                    await client.importProfile(name: name, content: content)
                    await client.fetchProfiles()
                    showImport = false
                }
            }
        }
        .sheet(isPresented: $showWizard) {
            ManualWizardView { profile in
                Task {
                    await client.saveProfile(profile)
                    await client.fetchProfiles()
                    showWizard = false
                }
            }
        }
        .sheet(isPresented: $showExport) {
            if let name = exportProfile {
                ExportConfView(profileName: name) { success in
                    showExport = false
                }
                .environmentObject(client)
            }
        }
        .sheet(item: $editProfile) { item in
            EditProfileView(profileName: item.name) {
                Task {
                    await client.fetchProfiles()
                    // 如果编辑的是当前使用的 profile，重新连接使其生效
                    if client.status?.service == item.name {
                        await client.post("disconnect")
                        await client.post("connect")
                    }
                }
                editProfile = nil
            }
            .environmentObject(client)
        }
        .confirmationDialog("确认删除？", isPresented: $showDeleteConfirm) {
            Button("删除 \(deleteProfile ?? "")", role: .destructive) {
                if let name = deleteProfile {
                    Task {
                        await client.deleteProfile(name: name)
                        await client.fetchProfiles()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task { await client.fetchProfiles() }
    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: "doc.badge.plus", tint: .orange, size: 44)
            Text("还没有配置")
                .font(.system(size: WgType.title, weight: .semibold))
            Text("导入 .conf 文件，或手动填写一份")
                .font(.system(size: WgType.sub))
                .foregroundStyle(.secondary)
            Button { showImport = true } label: { Text("导入配置") }
                .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                .wgPadding(.top, .s)
        }
        .frame(maxWidth: .infinity)
        .wgPadding(.xl)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    private func profileRow(_ name: String) -> some View {
        let isActive = client.status?.service == name
        return WgRow(
            symbol: "lock.shield.fill",
            tint: isActive ? .green : .gray,
            title: LocalizedStringKey(name),
            subtitle: isActive ? Text("使用中") : nil
        ) {
            HStack(spacing: WgSpace.zero) {
                if !isActive {
                    Button("切换") { Task { await client.switchProfile(name) } }
                        .buttonStyle(WgPillButtonStyle())
                        .wgPadding(.trailing, .s)
                }
                Button { editProfile = ProfileName(name: name) } label: { Image(systemName: "pencil") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("编辑")
                Button {
                    exportProfile = name
                    showExport = true
                } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("导出 .conf")
                Button {
                    deleteProfile = name
                    showDeleteConfirm = true
                } label: { Image(systemName: "trash") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("删除")
            }
        }
    }
}

// MARK: - 导入 .conf 文件

struct ImportConfView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String = ""
    @State private var fileContent: String = ""
    @State private var profileName: String = ""
    @State private var isDropTargeted = false
    @State private var error: String?
    let onComplete: (String, String) -> Void

    var body: some View {
        VStack(spacing: WgSpace.m) {
            Text("导入 WireGuard 配置").font(.title2).fontWeight(.semibold)

            // 拖拽区域
            VStack(spacing: WgSpace.s) {
                if fileContent.isEmpty {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: WgType.display))
                        .foregroundStyle(.tint)
                        .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3), value: isDropTargeted)

                    Text("拖拽 .conf 文件到此处")
                        .font(.headline)
                    Text("或点击下方按钮选择文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("选择文件") { pickFile() }
                        .buttonStyle(.borderedProminent)
                } else {
                    // 已加载预览
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: WgType.display))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))

                    Text(fileName).font(.headline)
                    ScrollView {
                        Text(fileContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .wgPadding(.s)
                    .wgSettingsPanelSurface()

                    Button("重新选择") {
                        fileContent = ""
                        fileName = ""
                        profileName = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .wgPadding(.xl)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: WgRadius.s)
                    .fill(isDropTargeted ? WgInk.signal.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: WgRadius.s)
                            .strokeBorder(
                                isDropTargeted ? WgInk.signal : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            // Profile 名称
            if !fileContent.isEmpty {
                VStack(alignment: .leading, spacing: WgSpace.s) {
                    Text("Profile 名称").font(.caption).foregroundStyle(.secondary)
                    TextField("如：home-vpn", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            // 底部按钮
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("导入") {
                    let name = profileName.isEmpty ? fileName.replacingOccurrences(of: ".conf", with: "") : profileName
                    onComplete(name, fileContent)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileContent.isEmpty)
            }
        }
        .wgPadding(.m)
        .frame(width: 480, height: 560)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: fileContent.isEmpty)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = String(localized: "选择 WireGuard 配置文件", bundle: .wgLocalized)
        panel.message = String(localized: "选择 .conf 文件", bundle: .wgLocalized)
        // 不限制文件类型，.conf 没有标准 UTType，用 allowedFileTypes 过滤扩展名
        panel.allowedFileTypes = ["conf", "txt"]
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { loadFile(url) }
                }
            }
        }
    }

    private func loadFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            fileContent = content
            fileName = url.lastPathComponent
            profileName = url.deletingPathExtension().lastPathComponent
            error = nil
        } catch {
            self.error = String(localized: "读取文件失败: \(error.localizedDescription)", bundle: .wgLocalized)
        }
    }
}

// MARK: - 导出 .conf 文件

struct ExportConfView: View {
    @EnvironmentObject var client: DaemonClient
    let profileName: String
    @State private var content: String = ""
    @State private var loaded = false
    @State private var done = false
    let onComplete: (Bool) -> Void

    var body: some View {
        VStack(spacing: WgSpace.m) {
            Text("导出 \(profileName)").font(.title2).fontWeight(.semibold)

            if !loaded {
                ProgressView("加载配置...")
            } else {
                Image(systemName: done ? "checkmark.circle.fill" : "doc.text.fill")
                    .font(.system(size: WgType.display))
                    .foregroundStyle(done ? Color.green : WgInk.signal)
                    .transition(.scale.combined(with: .opacity))

                Text(done ? "已保存到文件" : "配置内容预览").font(.headline)

                if !done {
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .wgPadding(.s)
                    .wgSettingsPanelSurface()

                    Button("保存到文件") { saveFile() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
            Button(done ? "完成" : "关闭") { onComplete(done) }
                .buttonStyle(.bordered)
        }
        .wgPadding(.m)
        .frame(width: 440, height: 420)
        .task {
            let result = await client.exportProfile(name: profileName)
            content = result
            loaded = true
        }
        .animation(.spring(response: 0.4), value: done)
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profileName).conf"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            done = true
        }
    }
}

// MARK: - 手动填写向导

struct ManualWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var profile = WGProfile()
    let onComplete: (WGProfile) -> Void

    private let steps = [String(localized: "名称", bundle: .wgLocalized), String(localized: "本机密钥", bundle: .wgLocalized), String(localized: "对端信息", bundle: .wgLocalized), String(localized: "确认", bundle: .wgLocalized)]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部进度指示器
            HStack(spacing: WgSpace.xs) {
                ForEach(0..<steps.count, id: \.self) { i in
                    HStack(spacing: WgSpace.s) {
                        Circle()
                            .fill(i <= step ? WgInk.signal : Color.secondary.opacity(0.3))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Group {
                                    if i < step {
                                        Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                                    } else {
                                        Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i <= step ? .white : .secondary)
                                    }
                                }
                            )
                            .scaleEffect(i == step ? 1.1 : 1.0)

                        Text(steps[i])
                            .font(.caption)
                            .foregroundStyle(i <= step ? .primary : .secondary)

                        if i < steps.count - 1 {
                            Rectangle()
                                .fill(i < step ? WgInk.signal : Color.secondary.opacity(0.2))
                                .frame(height: 1.5)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .wgPadding(.horizontal, .xl)
            .wgPadding(.top, .m)
            .wgPadding(.bottom, .m)

            Divider()

            // 步骤内容
            ZStack {
                if step == 0 {
                    VStack(spacing: WgSpace.m) {
                        wizardIcon("person.crop.circle.badge.questionmark")
                        wizardTitle("给你的配置起个名字", "方便后续识别和管理")
                        TextField("如：home-vpn", text: $profile.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }

                if step == 1 {
                    VStack(spacing: WgSpace.l) {
                        wizardIcon("key.fill")
                        wizardTitle("本机密钥信息", "来自你的 WireGuard 服务端配置")
                        VStack(spacing: WgSpace.m) {
                            wizardField("Private Key", "本机私钥 (base64)", text: $profile.privateKey, monospaced: true)
                            wizardField("Address", "本机隧道 IP (如 10.66.66.3/24)", text: $profile.address)
                            HStack(spacing: WgSpace.m) {
                                wizardField("DNS (可选)", "DNS 服务器", text: $profile.dns)
                                VStack(alignment: .leading, spacing: WgSpace.xs) {
                                    Text("MTU").font(.caption).foregroundStyle(.secondary)
                                    TextField("1420", value: $profile.mtu, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                            }
                        }
                        .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }

                if step == 2 {
                    VStack(spacing: WgSpace.l) {
                        wizardIcon("network")
                        wizardTitle("对端（服务器）信息", "WireGuard 服务端的连接信息")
                        VStack(spacing: WgSpace.m) {
                            wizardField("Public Key", "服务器公钥 (base64)", text: $profile.publicKey, monospaced: true)
                            wizardField("Endpoint", "服务器地址 (如 vpn.example.com:51820)", text: $profile.endpoint)
                            wizardField("Allowed IPs", "走隧道的网段", text: $profile.allowedIPs)
                            HStack(spacing: WgSpace.m) {
                                wizardField("Preshared Key (可选)", "预共享密钥", text: $profile.presharedKey, monospaced: true)
                                VStack(alignment: .leading, spacing: WgSpace.xs) {
                                    Text("Keepalive").font(.caption).foregroundStyle(.secondary)
                                    TextField("25", value: $profile.keepalive, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                            }
                        }
                        .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }

                if step == 3 {
                    VStack(spacing: WgSpace.l) {
                        wizardIcon("checkmark.seal.fill")
                        wizardTitle("确认配置信息", "检查无误后点击保存")
                        ScrollView {
                            VStack(alignment: .leading, spacing: WgSpace.s) {
                                reviewRow("名称", profile.name)
                                Divider()
                                reviewRow("Private Key", String(profile.privateKey.prefix(16)) + "...")
                                reviewRow("Address", profile.address)
                                if !profile.dns.isEmpty { reviewRow("DNS", profile.dns) }
                                reviewRow("MTU", "\(profile.mtu)")
                                Divider()
                                reviewRow("Public Key", String(profile.publicKey.prefix(16)) + "...")
                                reviewRow("Endpoint", profile.endpoint)
                                reviewRow("Allowed IPs", profile.allowedIPs)
                                if !profile.presharedKey.isEmpty {
                                    reviewRow("Preshared Key", String(profile.presharedKey.prefix(16)) + "...")
                                }
                                reviewRow("Keepalive", "\(profile.keepalive)s")
                            }
                            .wgPadding(.l)
                            .wgSettingsPanelSurface()
                        }
                        .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: step)
            .wgPadding(.top, .s)

            Divider()

            // 底部导航
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                if step > 0 {
                    Button("上一步") {
                        withAnimation { step -= 1 }
                    }
                    .buttonStyle(.bordered)
                }
                if step < steps.count - 1 {
                    Button("下一步") {
                        withAnimation { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("保存") {
                        onComplete(profile)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .wgPadding(.m)
        }
        .frame(width: 520, height: 560)
    }

    private var canProceed: Bool {
        switch step {
        case 0: return !profile.name.isEmpty
        case 1: return !profile.privateKey.isEmpty && !profile.address.isEmpty
        case 2: return !profile.publicKey.isEmpty && !profile.endpoint.isEmpty
        default: return true
        }
    }

    private func wizardIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: WgType.display))
            .foregroundStyle(WgInk.signal)
            .wgPadding(.bottom, .xs)
    }

    private func wizardTitle(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: WgSpace.xs) {
            Text(title).font(.title3).fontWeight(.semibold)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .wgPadding(.bottom, .s)
    }

    private func wizardField(_ label: LocalizedStringKey, _ placeholder: LocalizedStringKey, text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if monospaced {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reviewRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - 编辑 Profile

struct EditProfileView: View {
    @EnvironmentObject var client: DaemonClient
    @Environment(\.dismiss) private var dismiss
    let profileName: String
    let onSaved: () -> Void

    @State private var content: String = ""
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: WgSpace.l) {
            Text("编辑 \(profileName)").font(.title2).fontWeight(.semibold)

            if !loaded {
                ProgressView("加载配置...")
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .wgPadding(.s)
                    .wgSettingsPanelSurface()

                if saved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                HStack {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("保存") {
                        Task {
                            await client.updateProfile(name: profileName, content: content)
                            withAnimation { saved = true }
                            onSaved()
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(content.isEmpty)
                }
            }
        }
        .wgPadding(.m)
        .frame(width: 520, height: 500)
        .task {
            content = await client.loadProfileContent(name: profileName)
            loaded = true
        }
        .animation(.spring(response: 0.4), value: saved)
    }
}
