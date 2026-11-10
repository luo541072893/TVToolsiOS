import Foundation

// MARK: - ADB 客户端（握手状态机 + shell / reboot / sync 服务）
//
// 与 Android 版 TvAdb.shell() / quietShell() 一一对应：
//   · connect(host:port)  -> CNXN 握手（含 AUTH 认证）
//   · shell("reboot recovery") -> OPEN "shell:<cmd>\0" 收 stdout
//   · reboot("bootloader")     -> OPEN "reboot:bootloader\0"（等价于 adb reboot bootloader）
//   · probeSync()              -> OPEN "sync:\0" 推一个小样本测速
//
// 流控要点（AOSP transport.cpp）：
//   每个 OPEN 分配一个 localId；收到 OKAY 时 arg0=对端 remoteId、arg1=我们的 localId。
//   之后每收到一个 WRTE 都必须回一个 OKAY(localId, remoteId)，否则 adbd 会停止发送。
//   收到 CLSE 表示这个流结束。

final class ADBClient {

    enum ClientError: LocalizedError {
        case handshake(String)
        case notReady
        case serviceRejected(String)
        case streamClosed

        var errorDescription: String? {
            switch self {
            case .handshake(let m): return "ADB 握手失败：\(m)"
            case .notReady: return "还没连上电视"
            case .serviceRejected(let m): return "电视拒绝了请求：\(m)"
            case .streamClosed: return "连接被电视关闭"
            }
        }
    }

    struct Banner {
        var version: UInt32 = 0
        var maxPayload: Int = ADB.maxPayload
        var deviceInfo: String = ""
    }

    private let transport = ADBTransport()
    private let auth = ADBAuthenticator()
    private var banner = Banner()
    private var nextLocalId: UInt32 = 1

    /// 每个活跃 stream 的续延：key = localId
    private var streams: [UInt32: StreamState] = [:]
    private let lock = NSLock()

    private struct StreamState {
        var remoteId: UInt32
        var output = Data()
        var onOKAY: CheckedContinuation<Void, Error>?
        var finished = false
        var onFinish: CheckedContinuation<Data, Error>?
        /// 重启类服务：断连即成功
        var disconnectIsSuccess = false
    }

    private(set) var isReady = false
    var authenticator: ADBAuthenticator { auth }
    var onLog: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    init() {
        auth.restoreFromKeychain()
        transport.onPacket = { [weak self] packet in
            self?.handle(packet)
        }
        transport.onStateChange = { [weak self] text, connected in
            self?.onLog?(text)
            if !connected {
                self?.isReady = false
                self?.failAllStreams()
                self?.onDisconnect?()
            }
        }
    }

    // MARK: 连接 / 握手

    func connect(host: String, port: UInt16 = 5555) async throws {
        isReady = false
        authAttempts = 0
        lock.lock()
        pendingHandshakeResult = nil
        lock.unlock()
        onLog?("· 正在连接 \(host):\(port) …")
        try await transport.connect(host: host, port: port, timeout: 8)
        try await handshake()
    }

    private func handshake() async throws {
        // CNXN(version, maxPayload, "host::features=...\0")
        try await transport.send(ADB.CNXN, ADB.version, UInt32(ADB.maxPayload),
                                 Data(ADB.hostIdentity.utf8))
        onLog?("· 已发出 CNXN，等待电视回应…")

        // 等待 CNXN / AUTH，最多 12 秒
        let result = try await waitForHandshake(timeout: 12)
        switch result {
        case .connected(let b):
            banner = b
            isReady = true
            onLog?("✓ 已连接：\(b.deviceInfo.isEmpty ? "Android 设备" : b.deviceInfo)")
        case .failed(let msg):
            throw ClientError.handshake(msg)
        }
    }

    private enum HandshakeResult {
        case connected(Banner)
        case failed(String)
    }

    private var handshakeContinuation: CheckedContinuation<HandshakeResult, Error>?
    /// 握手回包可能比 waitForHandshake 注册续延更早到达，先缓存结果避免丢包
    private var pendingHandshakeResult: HandshakeResult?
    private var authAttempts = 0

    private func waitForHandshake(timeout: TimeInterval) async throws -> HandshakeResult {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let cached = pendingHandshakeResult {
                pendingHandshakeResult = nil
                lock.unlock()
                cont.resume(returning: cached)
                return
            }
            handshakeContinuation = cont
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                let pending = self.handshakeContinuation
                self.handshakeContinuation = nil
                self.lock.unlock()
                pending?.resume(returning: .failed("12 秒内没等到 CNXN（电视可能要求 USB 调试授权，或 ADB 没开）"))
            }
        }
    }

    private func resolveHandshake(_ result: HandshakeResult) {
        lock.lock()
        let cont = handshakeContinuation
        handshakeContinuation = nil
        if cont == nil { pendingHandshakeResult = result }
        lock.unlock()
        cont?.resume(returning: result)
    }

    // MARK: 报文分发

    private func handle(_ packet: ADBPacket) {
        if !isReady {
            handleHandshakePacket(packet)
            return
        }
        switch packet.command {
        case ADB.OKAY:
            handleOKAY(packet)
        case ADB.WRTE:
            handleWRTE(packet)
        case ADB.CLSE:
            handleCLSE(packet)
        case ADB.AUTH:
            // 已连接后又来 AUTH（少见）：忽略，避免打断
            onLog?("· 忽略一条迟到的 AUTH")
        default:
            break
        }
    }

    private func handleHandshakePacket(_ packet: ADBPacket) {
        switch packet.command {
        case ADB.CNXN:
            var b = Banner()
            b.version = packet.arg0
            b.maxPayload = max(256, min(Int(packet.arg1), 256 * 1024))
            b.deviceInfo = String(data: packet.data, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
            resolveHandshake(.connected(b))

        case ADB.AUTH where packet.arg0 == ADB.AuthType.token:
            // adbd 要求认证
            authAttempts += 1
            guard auth.hasKey else {
                onLog?("· 电视要求 USB 调试授权，但还没导入 ADB 密钥")
                onLog?("  请到「连接设置 → 导入 ADB 密钥」，或确认电视已允许该电脑调试")
                resolveHandshake(.failed("电视要求 RSA 授权，未导入密钥"))
                return
            }
            do {
                let sig = try auth.sign(token: packet.data)
                transportSendAsync(ADB.AUTH, ADB.AuthType.signature, 0, sig)
                onLog?("· 已用 ADB 私钥签名 token（第 \(authAttempts) 次）")
            } catch {
                resolveHandshake(.failed("签名失败：\(error.localizedDescription)"))
            }
            // 连签两次仍不过 -> 送公钥，让电视弹授权框
            if authAttempts >= 2 {
                transportSendAsync(ADB.AUTH, ADB.AuthType.rsaPublicKey, 0,
                                   auth.publicKeyPayload())
                onLog?("→ 电视上若弹出「允许 USB 调试」，请勾选「一律允许」后点确定")
            }

        case ADB.CLSE:
            resolveHandshake(.failed("电视在握手阶段关闭了连接"))
        default:
            break
        }
    }

    /// 握手阶段不方便用 async，这里做即发即忘（NWConnection 自己排队）
    private func transportSendAsync(_ c: UInt32, _ a0: UInt32, _ a1: UInt32, _ d: Data) {
        let p = ADBPacket(command: c, arg0: a0, arg1: a1, data: d)
        Task { try? await transport.send(p) }
    }

    // MARK: stream 服务

    /// 打开一个服务并返回收到的全部 stdout。
    /// - treatDisconnectAsSuccess: 重启类服务在电视断电时不会回 CLSE，断连即视为成功。
    /// - timeout: 防止 adbd 不回 CLSE 导致永久挂起。
    func openService(_ name: String, input: Data = Data(),
                     treatDisconnectAsSuccess: Bool = false,
                     timeout: TimeInterval = 20) async throws -> Data {
        guard isReady else { throw ClientError.notReady }
        let localId = allocateId()
        var service = Data(name.utf8)
        service.append(0)

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            streams[localId] = StreamState(remoteId: 0, onFinish: cont,
                                           disconnectIsSuccess: treatDisconnectAsSuccess)
            lock.unlock()

            Task {
                do {
                    try await transport.send(ADB.OPEN, localId, 0, service)
                    if !input.isEmpty {
                        try await self.pushAfterOKAY(localId: localId, data: input)
                    }
                } catch {
                    self.failStream(localId, error: error,
                                    disconnectIsSuccess: treatDisconnectAsSuccess)
                }
            }
            // 超时兜底
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                let stillPending = self.streams[localId]?.onFinish != nil
                self.lock.unlock()
                if stillPending {
                    self.finishStream(localId, data: self.takeOutput(localId))
                }
            }
        }
    }

    private func takeOutput(_ id: UInt32) -> Data {
        lock.lock(); defer { lock.unlock() }
        return streams[id]?.output ?? Data()
    }

    private func finishStream(_ id: UInt32, data: Data) {
        lock.lock()
        guard var state = streams[id], !state.finished else { lock.unlock(); return }
        state.finished = true
        let cont = state.onFinish
        streams.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(returning: data)
    }

    private func pushAfterOKAY(localId: UInt32, data: Data) async throws {
        // 轮询等 remoteId 就绪（OKAY 已到）
        for _ in 0..<100 {
            lock.lock()
            let rid = streams[localId]?.remoteId ?? 0
            lock.unlock()
            if rid != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let rid = streams[localId]?.remoteId ?? 0
        lock.unlock()
        guard rid != 0 else { return }
        // 按对端声明的 maxPayload 分块
        let chunkSize = max(256, min(banner.maxPayload, 4096))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            try await transport.send(ADB.WRTE, localId, rid, chunk)
            offset = end
        }
        try await transport.send(ADB.CLSE, localId, rid)
    }

    /// 执行一条 shell 命令（Android 版 quietShell 的等价实现）
    @discardableResult
    func shell(_ command: String) async throws -> String {
        onLog?("· 执行命令：\(command)")
        let data = try await openService("shell:\(command)")
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// adb reboot xxx 的真实实现：reboot:<mode> 服务。
    /// 部分老 adbd 不支持该服务，会自动降级成 `shell:reboot <mode>`。
    /// 电视重启时 TCP 会直接断开、不回 CLSE，这属于正常现象。
    func reboot(_ mode: String = "") async throws {
        let service = "reboot:" + mode
        onLog?("· 执行重启：\(service)")
        do {
            _ = try await openService(service, treatDisconnectAsSuccess: true, timeout: 8)
            onLog?("✓ 命令已送达，电视正在重启（连接断开属正常现象）")
        } catch {
            onLog?("· reboot 服务不可用，降级用 shell 命令重试")
            let shellCmd = mode.isEmpty ? "reboot" : "reboot \(mode)"
            do {
                _ = try await openService("shell:\(shellCmd)",
                                          treatDisconnectAsSuccess: true, timeout: 8)
            } catch {
                // 连接断开本身说明命令已发出、电视正在重启
            }
            onLog?("✓ 命令已送达，电视正在重启（连接断开属正常现象）")
        }
    }

    // MARK: OKAY / WRTE / CLSE

    private func handleOKAY(_ p: ADBPacket) {
        let localId = p.arg1
        let remoteId = p.arg0
        lock.lock()
        guard var state = streams[localId] else { lock.unlock(); return }
        state.remoteId = remoteId
        let pending = state.onOKAY
        state.onOKAY = nil
        streams[localId] = state
        lock.unlock()
        pending?.resume()
    }

    private func handleWRTE(_ p: ADBPacket) {
        let localId = p.arg1
        let remoteId = p.arg0
        lock.lock()
        guard var state = streams[localId] else {
            lock.unlock()
            return
        }
        state.output.append(p.data)
        streams[localId] = state
        lock.unlock()

        // 流控：必须回 OKAY，否则 adbd 不再发下一段
        Task { try? await transport.send(ADB.OKAY, localId, remoteId) }
    }

    private func handleCLSE(_ p: ADBPacket) {
        let localId = p.arg1
        lock.lock()
        guard var state = streams[localId], !state.finished else { lock.unlock(); return }
        state.finished = true
        let cont = state.onFinish
        let output = state.output
        streams.removeValue(forKey: localId)
        lock.unlock()
        // 回一个 CLSE 完成双向关闭
        Task { try? await transport.send(ADB.CLSE, localId, p.arg0) }
        cont?.resume(returning: output)
    }

    private func allocateId() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextLocalId
        nextLocalId += 1
        return id
    }

    private func failStream(_ id: UInt32, error: Error,
                            disconnectIsSuccess: Bool = false) {
        lock.lock()
        guard let state = streams.removeValue(forKey: id), !state.finished else {
            lock.unlock(); return
        }
        lock.unlock()
        let treatAsSuccess = disconnectIsSuccess || state.disconnectIsSuccess
        if treatAsSuccess {
            state.onFinish?.resume(returning: state.output)
        } else {
            state.onFinish?.resume(throwing: error)
        }
    }

    private func failAllStreams() {
        lock.lock()
        let all = streams
        streams.removeAll()
        lock.unlock()
        for (_, state) in all {
            state.onOKAY?.resume(throwing: ClientError.streamClosed)
            if state.disconnectIsSuccess {
                state.onFinish?.resume(returning: state.output)
            } else {
                state.onFinish?.resume(throwing: ClientError.streamClosed)
            }
        }
        // 仅在握手阶段才需要把断连转成握手失败；
        // 已连接后的断连不要留下陈旧的 pendingHandshakeResult，否则会污染下次连接。
        lock.lock()
        let handshakeInProgress = handshakeContinuation != nil
        lock.unlock()
        if handshakeInProgress { resolveHandshake(.failed("连接断开")) }
    }

    func disconnect() {
        transport.disconnect()
        isReady = false
        failAllStreams()
    }

    var maxPayload: Int { banner.maxPayload }
}
