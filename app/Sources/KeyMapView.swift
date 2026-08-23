import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「自定义按键音」窗口的内容：上半张键盘图，下半个音色库。
///
/// **为什么是键盘图而不是一张「键 → 音色」的表。** 指键这件事天然是空间性的：
/// 用户想的是「空格换成这个声」，不是「keyCode 49 换成这个声」。列表要求他先把
/// 键翻译成名字再去找那一行，而键盘图上他直接点那个键。代价是要维护一份布局表
/// （`KeyboardLayout`），换来的是这个功能第一眼就会用。
struct KeyMapView: View {

    @ObservedObject var store: CustomSoundStore
    @ObservedObject var settings: Settings

    /// 当前点开了哪个键的小面板。nil = 没点开
    @State private var openedKey: KeyCap?
    /// 导入失败的原因。贴在「导入…」按钮下面，不弹对话框——
    /// 一次可以选多个文件，其中几个不合格时对话框要弹好几次
    @State private var importProblem: String?
    /// 等待确认删除的音色。删除会连带清掉指键，不能点一下就没了
    @State private var pendingDelete: CustomSoundEntry?

    var body: some View {
        VStack(spacing: 0) {
            keyboardSection
            Divider()
            librarySection
        }
        .frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity)
        .frame(minHeight: 500, idealHeight: 620, maxHeight: .infinity)
        .confirmationDialog(
            pendingDelete.map { "删除「\($0.displayName)」？" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { delete(entry) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            if let entry = pendingDelete {
                let keys = store.assignments.values.filter { $0 == entry.id }.count
                Text(keys > 0
                     ? "指着它的 \(keys) 个键会一起恢复成音色包的声音。"
                     : "这条音色还没有指给任何键。")
            }
        }
    }

    // MARK: - 键盘图

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("点一个键，给它指一条音色").font(.headline)
                Spacer()
                Text("已指定 \(store.assignments.count) 个键")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            GeometryReader { geo in
                // 一个键位单位等于多少点。整张图按宽度缩放，
                // 所以窗口拉宽拉窄键盘都还是键盘的样子。
                let unit = geo.size.width / KeyboardLayout.unitsWide
                ZStack(alignment: .topLeading) {
                    ForEach(KeyboardLayout.keys) { cap in
                        keyCapView(cap, unit: unit)
                    }
                }
                .frame(width: geo.size.width, height: unit * KeyboardLayout.unitsHigh,
                       alignment: .topLeading)
            }
            .aspectRatio(KeyboardLayout.unitsWide / KeyboardLayout.unitsHigh, contentMode: .fit)

            // **先说做不到什么。** 这两条都会被当成 bug 报上来。
            VStack(alignment: .leading, spacing: 2) {
                Text("自定义音只替换**按下**的那一声，抬起仍然用音色包——"
                     + "两声都换成同一条采样，一次敲击会听到两遍一样的声音。")
                Text("F1–F12 若没在系统设置里设为标准功能键，直接按下发出的是"
                     + "亮度/音量之类的系统事件，不产生按键事件，指了也不会响。")
                Text("触控 ID 不产生按键事件，所以键盘图上没有画它。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func keyCapView(_ cap: KeyCap, unit: CGFloat) -> some View {
        let assigned = store.assignedSound(for: cap.keyCode)
        let active = assigned != nil && settings.keySoundCustomEnabled

        return Button {
            openedKey = cap
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.30)
                                 : Color.secondary.opacity(assigned != nil ? 0.22 : 0.10))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(active ? Color.accentColor
                                         : Color.secondary.opacity(assigned != nil ? 0.5 : 0.18),
                                  lineWidth: assigned != nil ? 1.5 : 0.5)
                Text(cap.label)
                    .font(.system(size: max(7, unit * 0.32)))
                    .foregroundStyle(assigned != nil ? AnyShapeStyle(.primary)
                                                     : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 2)
            }
            // 减 2pt 是键与键之间的缝。布局表里相邻的键是**贴边**的
            // （探针会验这一点），缝在画的时候留，不进布局表——
            // 否则「有没有重叠」这条检查就得先知道缝有多宽。
            .frame(width: max(1, cap.w * unit - 2), height: max(1, cap.h * unit - 2))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: cap.x * unit + 1, y: cap.y * unit + 1)
        .help(assigned.map { "\(cap.name)：\($0.displayName)" } ?? "\(cap.name)：未指定")
        .accessibilityLabel(cap.name)
        .accessibilityValue(assigned?.displayName ?? "未指定")
        // 每个键各挂一个 popover，但只有被点开的那个 binding 非 nil，
        // 所以同一时刻只会有一个真的显示出来。挂在外层容器上的话，
        // 小面板会飘在整张键盘的正中间，和点的那个键对不上。
        .popover(item: Binding(
            get: { openedKey?.keyCode == cap.keyCode ? cap : nil },
            set: { if $0 == nil { openedKey = nil } })
        ) { key in
            keyPopover(key)
        }
    }

    // MARK: - 单个键的小面板

    private func keyPopover(_ cap: KeyCap) -> some View {
        let assigned = store.assignedSound(for: cap.keyCode)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(cap.name).font(.headline)
                Spacer()
                Text("键码 \(cap.keyCode)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            if store.entries.isEmpty {
                Text("音色库还是空的。先用下面的「导入…」加一条采样进来。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.entries) { entry in
                            pickRow(entry, for: cap, isCurrent: entry.id == assigned?.id)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()
            HStack {
                Button("清除指定") {
                    store.assign(nil, to: cap.keyCode)
                }
                .disabled(assigned == nil)
                .help("这个键恢复成音色包的声音")

                Spacer()

                Button {
                    if let assigned { audition(assigned) }
                } label: {
                    Label("试听", systemImage: "play.circle")
                }
                .disabled(assigned == nil)
                .help("按这个键时会听到的声音")
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func pickRow(_ entry: CustomSoundEntry, for cap: KeyCap, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                // 再点一次已选中的那条 = 取消指定。省掉一次「先清除再选」
                store.assign(isCurrent ? nil : entry.id, to: cap.keyCode)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(entry.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                audition(entry)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("试听「\(entry.displayName)」")
            .accessibilityLabel("试听 \(entry.displayName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 音色库

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("音色库").font(.headline)
                Spacer()
                Toggle("启用自定义按键音", isOn: $settings.keySoundCustomEnabled)
                    .toggleStyle(.switch)
                    .accessibilityValue(settings.keySoundCustomEnabled ? "已开启" : "已关闭")
                    .help("关掉之后全部按键恢复成音色包的声音，指键关系保留")
                Button("导入…") { runImport() }
                    .help("支持常见音频格式，单条不超过 \(Int(CustomSoundStore.maxDuration)) 秒")
            }

            if let importProblem {
                Label(importProblem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("还没有导入任何采样。")
                    Text("导入时会自动把响度对齐到和内置音色包一样，"
                         + "所以自己录的声音不会突然比内置的响一大截。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            libraryRow(entry)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 100)
            }
        }
        .padding(16)
    }

    private func libraryRow(_ entry: CustomSoundEntry) -> some View {
        let used = store.assignments.values.filter { $0 == entry.id }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1).truncationMode(.middle)
                Text(used > 0 ? "指给了 \(used) 个键" : "未指给任何键")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                audition(entry)
            } label: {
                Label("试听", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("试听 \(entry.displayName)")

            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这条音色，指着它的键会恢复成音色包的声音")
            .accessibilityLabel("删除 \(entry.displayName)")
        }
        .padding(.vertical, 6)
    }

    // MARK: -

    /// 试听走独立的预览播放器，**不碰正在跑的那个** `KeySoundPlayer`——
    /// 理由见 `SoundPreviewPlayer` 的类注释。
    private func audition(_ entry: CustomSoundEntry) {
        SoundPreviewPlayer.shared.play(url: store.url(for: entry), gain: entry.gain)
    }

    private func delete(_ entry: CustomSoundEntry) {
        SoundPreviewPlayer.shared.forget(fileName: entry.fileName)
        store.remove(entry.id)
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "导入"
        panel.message = "选择一条按键音（不超过 \(Int(CustomSoundStore.maxDuration)) 秒）"
        guard panel.runModal() == .OK else { return }

        // 一次能选多个文件，所以失败要**逐条收集**再一起显示：
        // 中途 return 会让「选了五个、成功两个」变成只导进第一个。
        var problems: [String] = []
        for url in panel.urls {
            do {
                try store.importSound(from: url)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        importProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }
}
