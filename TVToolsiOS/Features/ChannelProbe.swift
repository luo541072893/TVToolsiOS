import Foundation

// MARK: - 传输通道体检（对齐 Android 版 TvAdb.probeAll）
//
// 原版结构（从 smali 反编译还原）：
//   ① 清点电视端工具：for c in sh cat nc netcat curl wget base64 stty toybox busybox
//                     md5sum md5 xxd dd; ... + busybox --list
//   ② Sync 快速通道      -> TvAdb.syncWithWatchdog()   sync: 服务
//   ③ 电视自取通道       -> HttpPush.push()           手机起 HTTP、电视 nc/curl/wget 来拉
//   ④ exec 裸管道        -> TvAdb.pushViaExec()       exec: 服务，不依赖电视端工具
//   ⑤ PTY 直传          -> TvAdb.pushViaCatRaw()     stty + cat
//   ⑥ base64 分段        -> TvAdb.pushViaBase64()     echo <b64> | base64 -d
//   ⑦ 八进制保底         -> TvAdb.pushViaOctal()      2KB 小样，printf 八进制转义
//
// iOS 版保持同样的 7 项与同样的"逐条测速 + 结论"结构。
// 每条通道都推一份固定小样本到 /data/local/tmp/.probe.bin，再校验文件大小/内容，
// 记录耗时并换算 KB/s，最后按原版 probeSummary 的口径给结论。

struct ProbeResult: Identifiable {
    let id = UUID()
    let name: String
    let available: Bool
    let seconds: Double
    let kbPerSecond: Double
    let note: String

    var line: String {
        if available {
            return "· \(name) 可用："
                + String(format: "%.1f", seconds) + " 秒 · "
                + String(format: "%.0f", kbPerSecond) + " KB/s  \(note)"
        }
        return "· \(name) 不行：\(note)"
    }
}

struct ChannelProbeReport {
    var tools: [String] = []
    var results: [ProbeResult] = []
    var summary: String = ""
    var tooSlowForAPK: Bool = false
}

final class ChannelProbe {

    private let client: ADBClient
    private let remotePath = "/data/local/tmp/.probe.bin"
    /// 256 KB 样本，与原版同类量级；八进制通道用 2 KB 小样
    private lazy var sample: Data = {
        var d = Data(capacity: 256 * 1024)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<(256 * 1024) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            d.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        return d
    }()

    init(client: ADBClient) { self.client = client }

    // MARK: 主流程

    func run(onLog: @escaping (String) -> Void) async -> ChannelProbeReport {
        var report = ChannelProbeReport()
        onLog("· 开始传输通道体检（1 次工具清点 + 6 条通道）")

        // ① 清点电视端工具
        await probeTools(report: &report, onLog: onLog)

        // ②~⑦ 六条通道
        let runners: [(String, () async -> ProbeResult)] = [
            ("Sync 快速通道",   { await self.probeSync(onLog: onLog) }),
            ("电视自取（nc/curl/wget）", { await self.probePull(onLog: onLog) }),
            ("exec 裸管道",     { await self.probeExec(onLog: onLog) }),
            ("PTY 直传（stty + cat）", { await self.probePTY(onLog: onLog) }),
            ("base64 分段",     { await self.probeBase64(onLog: onLog) }),
            ("八进制保底（2KB 小样）", { await self.probeOctal(onLog: onLog) }),
        ]
        for (name, runner) in runners {
            onLog("· 测 \(name)…")
            let r = await runner()
            report.results.append(r)
            onLog(r.line)
        }

        report.summary = makeSummary(report)
        report.tooSlowForAPK = isTooSlow(report)
        onLog(report.summary)
        if report.tooSlowForAPK {
            onLog("⚠ 这台电视的无线链路太慢，装一个 App 要等很久甚至传不完。")
            onLog("  建议：把 APK 拷到 U 盘插电视上直接装，比无线快得多；")
            onLog("  或者把电视接网线、手机和电视都靠近路由器再试一次（链路质量差是主因）。")
        }
        onLog("通道体检完成")
        return report
    }

    // MARK: ① 工具清点

    private func probeTools(report: inout ChannelProbeReport, onLog: (String) -> Void) async {
        let cmd = "for c in sh cat nc netcat curl wget base64 stty toybox busybox "
            + "md5sum md5 xxd dd; do [ -e /system/bin/$c ] && echo -n \"$c \"; "
            + "[ -e /system/xbin/$c ] && echo -n \"$c \"; done"
        onLog("· 清点电视端工具…")
        do {
            let out = try await client.shell(cmd)
            let list = out.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map(String.init).filter { !$0.isEmpty }
            report.tools = Array(Set(list)).sorted()
            onLog(report.tools.isEmpty ? "  （一条都没读到，可能连接已断）"
                                       : "  电视上有：" + report.tools.joined(separator: " "))
            let bb = try await client.shell("busybox --list 2>/dev/null")
            let bbList = bb.split(separator: "\n").map(String.init)
            let wanted = ["nc", "wget", "base64", "stty", "wc", "curl"]
            let hit = wanted.filter { bbList.contains($0) }
            if !hit.isEmpty { onLog("  busybox 带有：" + hit.joined(separator: " ")) }
        } catch {
            onLog("  （工具清点失败：\(error.localizedDescription)）")
        }
    }

    // MARK: 通用校验：推完样本后检查电视端文件大小

    private func remoteSize() async -> Int? {
        guard let out = try? await client.shell("wc -c < \(remotePath) 2>/dev/null") else {
            return nil
        }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cleanup() async {
        _ = try? await client.shell("rm -f \(remotePath)")
    }

    private func measure(name: String, note: String = "",
                         body: () async throws -> Void) async -> ProbeResult {
        await cleanup()
        let start = Date()
        do {
            try await body()
            let elapsed = Date().timeIntervalSince(start)
            let size = await remoteSize() ?? 0
            guard size > 0 else {
                return ProbeResult(name: name, available: false, seconds: elapsed,
                                   kbPerSecond: 0, note: "样本没写成功")
            }
            let kbps = Double(size) / 1024.0 / max(elapsed, 0.001)
            return ProbeResult(name: name, available: true, seconds: elapsed,
                               kbPerSecond: kbps, note: note)
        } catch {
            return ProbeResult(name: name, available: false,
                               seconds: Date().timeIntervalSince(start),
                               kbPerSecond: 0, note: error.localizedDescription)
        }
    }

    // MARK: ② Sync 快速通道

    private func probeSync(onLog: (String) -> Void) async -> ProbeResult {
        await measure(name: "Sync 快速通道", note: "（sync: 服务）") {
            let frames = ADBSyncFrames.send(remotePath: self.remotePath,
                                            data: self.sample,
                                            chunkSize: self.client.maxPayload)
            let resp = try await self.client.openService("sync:", input: frames, timeout: 12)
            if let fail = ADBSyncFrames.failureMessage(resp) {
                throw NSError(domain: "probe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: fail])
            }
            guard ADBSyncFrames.containsOKAY(resp) else {
                throw NSError(domain: "probe", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "adbd 没回 OKAY"])
            }
        }
    }

    // MARK: ③ 电视自取通道

    private func probePull(onLog: (String) -> Void) async -> ProbeResult {
        guard let ip = ProbeHTTPServer.localIPv4() else {
            return ProbeResult(name: "电视自取（nc/curl/wget）", available: false,
                               seconds: 0, kbPerSecond: 0, note: "拿不到 iPhone 的局域网 IP")
        }
        let server = ProbeHTTPServer(payload: sample)
        do { try server.start() } catch {
            return ProbeResult(name: "电视自取（nc/curl/wget）", available: false,
                               seconds: 0, kbPerSecond: 0, note: error.localizedDescription)
        }
        defer { server.stop() }
        let url = "http://\(ip):\(server.port)/probe.bin"
        onLog("  电视自取地址：\(url)")

        return await measure(name: "电视自取（nc/curl/wget）", note: "（反向拉取）") {
            // 依次尝试电视上可能存在的下载工具
            let cmd = "(wget -q -O \(self.remotePath) '\(url)' 2>/dev/null"
                + " || curl -s -o \(self.remotePath) '\(url)' 2>/dev/null"
                + " || nc \(ip) \(server.port) < /dev/null > \(self.remotePath) 2>/dev/null)"
            _ = try await self.client.shell(cmd)
        }
    }

    // MARK: ④ exec 裸管道

    private func probeExec(onLog: (String) -> Void) async -> ProbeResult {
        await measure(name: "exec 裸管道", note: "（不依赖电视端工具）") {
            // exec: 把 stdin 直接交给命令；cat 把字节写进文件
            let body = try await self.client.openService(
                "exec:cat > \(self.remotePath)", input: self.sample, timeout: 12)
            _ = body
        }
    }

    // MARK: ⑤ PTY 直传（stty + cat）

    private func probePTY(onLog: (String) -> Void) async -> ProbeResult {
        await measure(name: "PTY 直传（stty + cat）", note: "（需 stty，7.0 以下没有）") {
            let out = try await self.client.shell(
                "stty -echo raw 2>/dev/null; cat > \(self.remotePath)")
            _ = out
        }
    }

    // MARK: ⑥ base64 分段

    private func probeBase64(onLog: (String) -> Void) async -> ProbeResult {
        await measure(name: "base64 分段", note: "（shell 分段写入）") {
            let b64 = self.sample.base64EncodedString()
            _ = try await self.client.shell("rm -f \(self.remotePath)")
            // 分段，避免单条命令过长
            let chunk = 12 * 1024
            var i = 0
            while i < b64.count {
                let end = min(i + chunk, b64.count)
                let part = String(b64[b64.index(b64.startIndex, offsetBy: i)..<
                                      b64.index(b64.startIndex, offsetBy: end)])
                _ = try await self.client.shell(
                    "printf '%s' '\(part)' | base64 -d >> \(self.remotePath) 2>/dev/null")
                i = end
            }
        }
    }

    // MARK: ⑦ 八进制保底（2KB 小样）

    private func probeOctal(onLog: (String) -> Void) async -> ProbeResult {
        let small = sample.prefix(2048)
        return await measure(name: "八进制保底（2KB 小样）", note: "（printf 八进制转义）") {
            let escaped = small.map { String(format: "\\%03o", Int($0)) }.joined()
            _ = try await self.client.shell(
                "printf '\(escaped)' > \(self.remotePath) 2>/dev/null")
        }
    }

    // MARK: 结论（对齐原版 probeSummary / tooSlowForApk 口径）

    private func makeSummary(_ r: ChannelProbeReport) -> String {
        let ok = r.results.filter { $0.available }
        guard let fastest = ok.min(by: { $0.seconds < $1.seconds }) else {
            return "结论：这台电视一条通道都没走通"
        }
        let kbps = fastest.kbPerSecond
        let apkSeconds = 25 * 1024.0 / max(kbps, 0.001)   // 按 25 MB 的 APK 估
        let timeText: String
        if apkSeconds < 90 {
            timeText = String(format: "，装一个 App 约 %.0f 秒", apkSeconds)
        } else if apkSeconds < 3600 {
            timeText = String(format: "，装一个 App 约 %.0f 分钟", apkSeconds / 60)
        } else {
            timeText = String(format: "，装一个 App 要 %.1f 小时", apkSeconds / 3600)
        }
        return "结论：\(ok.count) 条通道可用，最快：\(fastest.name)（"
            + String(format: "%.1f", fastest.seconds) + " 秒）" + timeText
    }

    private func isTooSlow(_ r: ChannelProbeReport) -> Bool {
        guard let best = r.results.filter({ $0.available }).max(by: {
            $0.kbPerSecond < $1.kbPerSecond
        }) else { return true }
        return best.kbPerSecond < 100   // 低于 100 KB/s 认为传 APK 不现实
    }
}
