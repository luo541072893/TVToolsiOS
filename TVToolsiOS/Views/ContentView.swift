import SwiftUI
import UIKit

// MARK: - 首页
//
// 与 Android 版 buildUi() 的卡片结构一致：
//   顶部连接条 → 高级功能卡片 → 日志区

struct ContentView: View {
    @EnvironmentObject private var session: TVSession
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "tvtools.welcomed")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    advancedCard
                    logPanel
                }
                .padding()
            }
            .navigationTitle("TV桌面工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        session.showConnectSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $session.showAdvancedMenu) { AdvancedMenuView() }
            .sheet(isPresented: $session.showChannelReport) { ChannelCheckView() }
            .sheet(isPresented: $session.showConnectSheet) { ConnectionView() }
            .sheet(isPresented: $showWelcome) {
                WelcomeView {
                    UserDefaults.standard.set(true, forKey: "tvtools.welcomed")
                    showWelcome = false
                }
            }
        }
        .environmentObject(session)
    }

    // MARK: 连接条

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(session.isConnected ? "●  已连接" : "●  未连接")
                    .font(.subheadline)
                    .foregroundStyle(session.isConnected ? .green : .secondary)
                Spacer()
                Text(session.settings.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(session.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task { await session.connect() }
                } label: {
                    Label(session.isConnected ? "重新连接" : "连接电视",
                          systemImage: "cable.connector")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy)

                Button {
                    session.disconnect()
                } label: {
                    Label("断开", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!session.isConnected)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 高级功能卡片

    private var advancedCard: some View {
        Button {
            session.showAdvancedMenu = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AdvancedMenu.cardTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(AdvancedMenu.cardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: 日志区

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("操作日志")
                    .font(.headline)
                Spacer()
                Button("清空") { session.log.clear() }
                    .font(.caption)
                Button {
                    UIPasteboard.general.string = session.log.text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .font(.caption)
            }
            ScrollView {
                Text(session.log.text.isEmpty ? "做了什么都会记在这里。" : session.log.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(session.log.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 260)
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground),
                       in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 首次启动说明

struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("一台 iPhone 管理安卓电视的小工具")
                        .font(.title3.bold())
                    Text("不用 root、不用往电视里装任何东西，所有操作走无线调试（ADB over TCP），每做一步都会记录在日志区里。")
                        .font(.body)
                    Divider()
                    Text("使用前请确认").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("① iPhone 和电视连同一个 Wi-Fi")
                        Text("② 电视已打开「网络调试（ADB）」开关")
                        Text("③ 知道电视的 IP 地址")
                        Text("④ 首次连接会请求「本地网络」权限，请允许")
                    }
                    .font(.subheadline)
                    Divider()
                    Text("⚠ 本工具会向电视发送 reboot / 卸载类命令，请确认目标设备正确后再执行。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                .padding()
            }
            .navigationTitle("欢迎使用")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始使用", action: onDismiss)
                }
            }
        }
    }
}
