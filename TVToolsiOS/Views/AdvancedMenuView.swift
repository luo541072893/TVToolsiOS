import SwiftUI

// MARK: - 高级功能（子菜单）
//
// 用户指定的菜单树：
//   首页 → 高级功能（卡片）
//        → 高级功能（子菜单，弹出标题）
//            ├── 重启到Recovery   → reboot recovery
//            ├── 重启到Fastboot   → reboot bootloader
//            ├── 重启到sideload   → reboot sideload
//            ├── 正常重启          → reboot
//            └── 传输通道体检      → 原七通道体检（逻辑原样保留）

struct AdvancedMenuView: View {
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCommand: AdvancedCommand?
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AdvancedMenu.commands) { command in
                        Button {
                            pendingCommand = command
                            showConfirm = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: command.symbol)
                                    .font(.title3)
                                    .foregroundStyle(command.destructive ? .orange : .tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.label)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(command.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("重启命令")
                } footer: {
                    Text("命令通过无线 ADB 直接发给电视。执行后电视会立即重启、连接断开属正常现象。")
                }

                Section {
                    Button {
                        dismiss()
                        // 等 sheet 收起后再弹报告，避免 sheet 嵌套
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            await session.runChannelProbe()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "stethoscope")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(AdvancedMenu.healthCheckTitle)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(AdvancedMenu.healthCheckSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!session.isConnected)
                } header: {
                    Text("诊断")
                } footer: {
                    Text(session.isConnected ? "逐条测试 6 条传输通道并测速。" : "请先连接电视。")
                }
            }
            .navigationTitle(AdvancedMenu.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("确认执行", isPresented: $showConfirm, presenting: pendingCommand) { cmd in
                Button("取消", role: .cancel) { pendingCommand = nil }
                Button(cmd.label, role: cmd.destructive ? ButtonRole.destructive : nil) {
                    let target = cmd
                    pendingCommand = nil
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await session.runReboot(target)
                    }
                }
            } message: { cmd in
                Text("将向 \(session.settings.host) 发送：\n"
                     + "adb \(cmd.mode.isEmpty ? "reboot" : "reboot \(cmd.mode)")\n\n"
                     + "电视会立即重启，未保存的内容可能丢失。")
            }
        }
    }
}
