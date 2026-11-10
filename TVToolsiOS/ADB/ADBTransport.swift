import Foundation
import Network

// MARK: - TCP 传输层
//
// 用 Network.framework 的 NWConnection 直连电视 5555 端口（无线 ADB）。
// iOS 14+ 访问局域网需要 Info.plist 里声明 NSLocalNetworkUsageDescription，
// 首次连接系统会弹一次授权框。
//
// ADB 是"报文协议 over 字节流"，所以这里只负责：
//   - 建立/断开 TCP
//   - 把收到的字节喂给 ADBPacketCoder 做流式拆包
//   - 对外抛出一个个完整的 ADBPacket

final class ADBTransport {

    enum TransportError: LocalizedError {
        case invalidPort
        case notConnected
        case protocolError(String)
        case timeout
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "端口不合法"
            case .notConnected: return "尚未连接电视"
            case .protocolError(let m): return "ADB 报文异常：\(m)"
            case .timeout: return "电视无响应（可能休眠了，或 ADB 未打开）"
            case .connectionFailed(let m): return "连不上电视：\(m)"
            }
        }
    }

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "tvtools.adb.transport", qos: .userInitiated)
    private var receiveBuffer = Data()

    /// 每解出一个完整报文就回调一次
    var onPacket: ((ADBPacket) -> Void)?
    var onStateChange: ((String, Bool) -> Void)?   // (描述, 是否已连接)

    private(set) var isConnected = false

    func connect(host: String, port: UInt16 = 5555, timeout: TimeInterval = 8) async throws {
        guard port > 0 else { throw TransportError.invalidPort }
        disconnect()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // ADB 是长连接，禁止系统把空闲连接判定为可丢弃
        parameters.includePeerToPeer = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.invalidPort
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = conn
        receiveBuffer = Data()

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.onStateChange?("已连上 \(host):\(port)", true)
                self.pumpReceive()
            case .failed(let error):
                self.isConnected = false
                self.onStateChange?("连接失败：\(error.localizedDescription)", false)
            case .cancelled:
                self.isConnected = false
                self.onStateChange?("连接已断开", false)
            case .waiting(let error):
                self.onStateChange?("等待网络：\(error.localizedDescription)", false)
            default:
                break
            }
        }
        conn.start(queue: queue)

        // 等待 ready（带超时）
        try await waitForReady(timeout: timeout)
    }

    private func waitForReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected {
            if let conn = connection, case .failed(let err) = conn.state {
                throw TransportError.connectionFailed(err.localizedDescription)
            }
            if Date() > deadline { throw TransportError.timeout }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    func send(_ packet: ADBPacket) async throws {
        guard isConnected, let conn = connection else { throw TransportError.notConnected }
        let bytes = ADBPacketCoder.encode(packet)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: bytes, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func send(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ data: Data = Data()) async throws {
        try await send(ADBPacket(command: command, arg0: arg0, arg1: arg1, data: data))
    }

    /// 持续收包：NWConnection 给的是任意长度字节片，累积后循环拆包
    private func pumpReceive() {
        guard let conn = connection, isConnected else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainBuffer()
            }
            if let error {
                self.isConnected = false
                self.onStateChange?("接收中断：\(error.localizedDescription)", false)
                return
            }
            if isComplete {
                self.isConnected = false
                self.onStateChange?("电视关闭了连接（重启时属正常现象）", false)
                return
            }
            self.pumpReceive()
        }
    }

    private func drainBuffer() {
        while true {
            let (packet, consumed) = ADBPacketCoder.decode(receiveBuffer)
            if consumed < 0 {
                isConnected = false
                onStateChange?("ADB 报文头校验失败，已断开", false)
                receiveBuffer.removeAll()
                return
            }
            guard let packet, consumed > 0 else { break }
            receiveBuffer.removeSubrange(0..<consumed)
            onPacket?(packet)
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        receiveBuffer.removeAll()
    }
}
