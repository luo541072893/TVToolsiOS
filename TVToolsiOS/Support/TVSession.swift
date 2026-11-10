import SwiftUI

// MARK: - 全局会话（持有唯一的 ADBClient，供所有视图共享）

@MainActor
final class TVSession: ObservableObject {
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var statusText = "未连接"
    @Published var showAdvancedMenu = false
    @Published var showChannelReport = false
    @Published var showConnectSheet = false
    @Published var channelReport: ChannelProbeReport?

    let client = ADBClient()
    let log = LogStore()
    let settings = AppSettings()

    init() {
        client.onLog = { [weak self] text in
            Task { @MainActor in self?.log.append(text) }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.statusText = "连接已断开"
            }
        }
    }

    func connect() async {
        isBusy = true
        statusText = "正在连接…"
        defer { isBusy = false }
        do {
            try await client.connect(host: settings.host, port: settings.portValue)
            isConnected = true
            statusText = "已连接 \(settings.host):\(settings.port)"
            log.append("✓ 连接成功")
        } catch {
            isConnected = false
            statusText = "连接失败"
            log.append("✗ \(error.localizedDescription)")
            log.append("  ① 手机和电视要连同一个 Wi-Fi")
            log.append("  ② 电视「设置 → 账号与安全 → 网络调试(ADB)」已打开")
            log.append("  ③ 电视 IP 是否输对：设置 → 关于 → 状态")
            log.append("  ④ 部分固件重启后会自动关掉 ADB，要重新开一次")
        }
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
        statusText = "未连接"
        log.append("· 已断开")
    }

    func runReboot(_ command: AdvancedCommand) async {
        guard isConnected else { log.append("先连接电视"); return }
        isBusy = true
        defer { isBusy = false }
        // 重启会断开连接，提前更新 UI
        do {
            try await client.reboot(command.mode)
        } catch {
            log.append("✗ \(error.localizedDescription)")
        }
        isConnected = false
        statusText = "电视正在重启"
    }

    func runChannelProbe() async {
        guard isConnected else { log.append("先连接电视，再体检"); return }
        isBusy = true
        showChannelReport = true
        defer { isBusy = false }
        let probe = ChannelProbe(client: client)
        let report = await probe.run { [weak self] text in
            Task { @MainActor in self?.log.append(text) }
        }
        channelReport = report
    }
}
