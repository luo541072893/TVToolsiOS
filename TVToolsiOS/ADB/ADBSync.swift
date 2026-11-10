import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ADB sync: 协议帧构造
//
// AOSP system/core/adb/file_sync_service.cpp：
//   SEND = "SEND" + uint32_le(pathAndMode 长度) + "<path>,<mode>"
//   DATA = "DATA" + uint32_le(数据长度) + 数据
//   DONE = "DONE" + uint32_le(mtime)
//   adbd 回 OKAY = "OKAY" + uint32_le(0)，或 FAIL = "FAIL" + uint32_le(msg 长度) + msg
//
// 所有长度都是小端 uint32。这里只构造"推一个小样本"所需的帧。

enum ADBSyncFrames {

    static func fourCC(_ s: String) -> Data {
        Data(s.utf8)
    }

    static func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    /// 构造一次完整 SEND 的报文字节流（推到 /data/local/tmp/.probe.bin）
    static func send(remotePath: String, data: Data, chunkSize: Int = 4096) -> Data {
        var out = Data()

        // SEND
        let pathAndMode = "\(remotePath),0644"
        let pm = Data(pathAndMode.utf8)
        out.append(fourCC("SEND"))
        out.append(le32(UInt32(pm.count)))
        out.append(pm)

        // DATA（按 maxPayload 分块）
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            out.append(fourCC("DATA"))
            out.append(le32(UInt32(chunk.count)))
            out.append(chunk)
            offset = end
        }

        // DONE
        out.append(fourCC("DONE"))
        out.append(le32(UInt32(Date().timeIntervalSince1970)))
        return out
    }

    /// 解析 adbd 回包里是否出现 OKAY（按字节找，避免二进制内容让 ASCII 解码失败）
    static func containsOKAY(_ response: Data) -> Bool {
        let needle = Data("OKAY".utf8)
        return response.range(of: needle) != nil
    }

    static func failureMessage(_ response: Data) -> String? {
        let needle = Data("FAIL".utf8)
        guard let r = response.range(of: needle) else { return nil }
        let tail = response[r.upperBound...]
        // FAIL 帧：4 字节长度 + 消息，跳过长度字段
        let msg = tail.count > 4 ? tail.dropFirst(4) : tail
        return String(data: Data(msg), encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
    }
}

// MARK: - 极简本地 HTTP 服务（用于「电视自取」通道）
//
// 原版 Android 的 HttpPush 是手机起 HTTP 服务、让电视用 nc / curl / wget
// 反过来把 APK 拉走。iOS 版同样用 NWListener 监听一个随机端口，
// 电视执行 `wget http://<iPhone-IP>:<port>/probe.bin` 即可。

final class ProbeHTTPServer {

    enum ServerError: LocalizedError {
        case noPort
        var errorDescription: String? { "无法启动本地 HTTP 服务" }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tvtools.probe.http")
    let payload: Data

    private(set) var port: UInt16 = 0
    private(set) var servedBytes: Int = 0

    init(payload: Data) { self.payload = payload }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = l.port?.rawValue {
                self?.port = port
            }
        }
        listener = l
        l.start(queue: queue)

        // 等端口就绪
        let deadline = Date().addingTimeInterval(2)
        while port == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard port != 0 else { throw ServerError.noPort }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else { return }
            if data != nil {
                // 不解析请求方法，任何 GET 都返回同一个小样本
                let body = self.payload
                self.servedBytes += body.count
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var response = Data(header.utf8)
                response.append(body)
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    /// 获取 iPhone 在当前局域网的 IPv4（用于拼给电视的 URL）
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let head = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            let name = String(cString: p.pointee.ifa_name)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  name.hasPrefix("en"),
                  let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &buf, socklen_t(buf.count),
                                 nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                let ip = String(cString: buf)
                if !ip.isEmpty { return ip }
            }
        }
        return nil
    }
}
