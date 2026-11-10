import Foundation

// MARK: - ADB 报文协议常量
//
// 与 tools/adb_protocol_selftest.py 一一对应（该脚本已通过 10 项字节级自测）。
// 参考 AOSP system/core/adb/adb.h、adb/transport.cpp、adb/adb_auth_host.cpp。
//
// 一个 ADB 报文 = 24 字节头（6 个小端 uint32）+ payload：
//   command, arg0, arg1, data_length, data_check(纯字节和), magic(command ^ 0xffffffff)
//
// 命令字是 4 个 ASCII 字符按小端 uint32 读出来的值，例如 "CNXN" -> 0x4E584E43。

enum ADB {

    static func command(_ fourCC: String) -> UInt32 {
        precondition(fourCC.utf8.count == 4, "ADB 命令字必须是 4 个 ASCII 字符")
        var value: UInt32 = 0
        for (i, byte) in fourCC.utf8.enumerated() {
            value |= UInt32(byte) << (8 * UInt32(i))
        }
        return value
    }

    static let SYNC: UInt32 = 0x434E5953
    static let CNXN: UInt32 = 0x4E584E43
    static let OPEN: UInt32 = 0x4E45504F
    static let OKAY: UInt32 = 0x59414B4F
    static let CLSE: UInt32 = 0x45534C43
    static let WRTE: UInt32 = 0x45545257
    static let AUTH: UInt32 = 0x48545541

    /// AOSP: #define A_VERSION 0x01000000
    static let version: UInt32 = 0x01000000

    /// 最保守的 max payload，任何版本 adbd 都接受。
    /// 握手成功后会按对端 CNXN 回包里 arg1 的值更新。
    static let maxPayload = 4096

    enum AuthType {
        static let token: UInt32 = 1           // adbd -> host，20 字节随机 token
        static let signature: UInt32 = 2       // host -> adbd，RSA 签名
        static let rsaPublicKey: UInt32 = 3    // host -> adbd，adbkey.pub 内容（含 \0）
    }

    static let tokenSize = 20

    /// 本机标识，用于 CNXN 的 "host::..." 与 adbkey.pub 的尾部注释
    static let hostIdentity = "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,abb,abb_exec,remount_shell,fixed_push_symlink_timestamp\0"
}

// MARK: - 报文结构

struct ADBPacket {
    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let data: Data

    var commandName: String {
        var v = command
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    var isCNXN: Bool { command == ADB.CNXN }
    var isAUTH: Bool { command == ADB.AUTH }
    var isOPEN: Bool { command == ADB.OPEN }
    var isOKAY: Bool { command == ADB.OKAY }
    var isCLSE: Bool { command == ADB.CLSE }
    var isWRTE: Bool { command == ADB.WRTE }
}

// MARK: - 编解码

enum ADBPacketCoder {

    /// payload 校验和 = 所有字节的无符号和（不是 CRC），与 AOSP calculate_apacket_checksum 一致
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt64 = 0
        for byte in data { sum += UInt64(byte) }
        return UInt32(sum & 0xFFFF_FFFF)
    }

    static func encode(_ packet: ADBPacket) -> Data {
        var out = Data()
        out.reserveCapacity(24 + packet.data.count)
        appendLE(packet.command, to: &out)
        appendLE(packet.arg0, to: &out)
        appendLE(packet.arg1, to: &out)
        appendLE(UInt32(packet.data.count), to: &out)
        appendLE(checksum(packet.data), to: &out)
        appendLE(packet.command ^ 0xFFFF_FFFF, to: &out)
        out.append(packet.data)
        return out
    }

    static func encode(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ data: Data = Data()) -> Data {
        encode(ADBPacket(command: command, arg0: arg0, arg1: arg1, data: data))
    }

    /// 把一段字符串（含结尾 \0）作为 payload
    static func encode(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ text: String) -> Data {
        var data = Data(text.utf8)
        data.append(0)
        return encode(command, arg0, arg1, data)
    }

    /// 从字节流缓冲区头部尝试解一个包。
    /// 返回 (包, 消耗的字节数)；数据不足时返回 (nil, 0)，调用方保留缓冲区等下一次收包。
    static func decode(_ buffer: Data) -> (ADBPacket?, Int) {
        guard buffer.count >= 24 else { return (nil, 0) }
        let command = readLE(buffer, at: 0)
        let arg0 = readLE(buffer, at: 4)
        let arg1 = readLE(buffer, at: 8)
        let length = Int(readLE(buffer, at: 12))
        let check = readLE(buffer, at: 16)
        let magic = readLE(buffer, at: 20)

        guard (command ^ 0xFFFF_FFFF) == magic else {
            return (nil, -1)   // -1 表示协议错误，调用方应断开连接
        }
        guard length <= 1 << 20 else { return (nil, -1) }
        guard buffer.count >= 24 + length else { return (nil, 0) }

        let payload = buffer.subdata(in: 24..<(24 + length))
        guard checksum(payload) == check else { return (nil, -1) }

        let packet = ADBPacket(command: command, arg0: arg0, arg1: arg1, data: payload)
        return (packet, 24 + length)
    }

    // 小端读写，避免依赖 Data 的对齐
    private static func appendLE(_ value: UInt32, to data: inout Data) {
        let v = value.littleEndian
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }

    private static func readLE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * UInt32(i))
        }
        return value
    }
}
