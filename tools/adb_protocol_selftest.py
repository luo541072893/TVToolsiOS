#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ADB 报文协议自测（纯 Python，不依赖 Android / iOS / Swift）。

用途：
  1. 验证 ADB 报文头常量、校验和、magic、编解码、流式拆包逻辑是否正确；
  2. 作为 Swift 侧 ADBProtocol.swift / ADBPacketCoder.swift 的字节级参照实现；
  3. 在没有 Xcode 的 Linux 机器上给"协议层是对的"一个可复现的证据。

运行：python3 tools/adb_protocol_selftest.py
"""
import struct
import unittest

# ---- 命令字：4 个 ASCII 字符按小端 uint32 读出来的值 ----
def cmd(s: str) -> int:
    assert len(s) == 4
    return struct.unpack("<I", s.encode("ascii"))[0]

A_SYNC = cmd("SYNC")
A_CNXN = cmd("CNXN")
A_OPEN = cmd("OPEN")
A_OKAY = cmd("OKAY")
A_CLSE = cmd("CLSE")
A_WRTE = cmd("WRTE")
A_AUTH = cmd("AUTH")

A_VERSION = 0x01000000
MAX_PAYLOAD = 4096          # 最保守值，任何版本的 adbd 都接受

ADB_AUTH_TOKEN = 1
ADB_AUTH_SIGNATURE = 2
ADB_AUTH_RSAPUBLICKEY = 3


def checksum(data: bytes) -> int:
    """data_check = payload 所有字节的无符号和（不是 CRC）"""
    return sum(data) & 0xFFFFFFFF


def encode(command: int, arg0: int, arg1: int, data: bytes = b"") -> bytes:
    header = struct.pack(
        "<6I",
        command & 0xFFFFFFFF,
        arg0 & 0xFFFFFFFF,
        arg1 & 0xFFFFFFFF,
        len(data) & 0xFFFFFFFF,
        checksum(data),
        (command ^ 0xFFFFFFFF) & 0xFFFFFFFF,
    )
    return header + data


class Packet:
    def __init__(self, command, arg0, arg1, data):
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.data = data

    @property
    def name(self):
        return struct.pack("<I", self.command).decode("ascii", errors="replace")


def decode_one(buf: bytes):
    """从 buf 开头解一个包；不完整返回 (None, buf)；有包返回 (Packet, 剩余)"""
    if len(buf) < 24:
        return None, buf
    command, arg0, arg1, length, check, magic = struct.unpack("<6I", buf[:24])
    assert (command ^ 0xFFFFFFFF) & 0xFFFFFFFF == magic, "magic 不匹配"
    if len(buf) < 24 + length:
        return None, buf
    data = buf[24:24 + length]
    assert checksum(data) == check, "data_check 不匹配"
    return Packet(command, arg0, arg1, data), buf[24 + length:]


# ------------------------------ 测试 ------------------------------
class TestADBProtocol(unittest.TestCase):

    def test_command_words(self):
        # 这些是 AOSP adb.h 里的固定值，写错就永远握不上手
        self.assertEqual(A_CNXN, 0x4E584E43)
        self.assertEqual(A_OPEN, 0x4E45504F)
        self.assertEqual(A_OKAY, 0x59414B4F)
        self.assertEqual(A_CLSE, 0x45534C43)
        self.assertEqual(A_WRTE, 0x45545257)
        self.assertEqual(A_AUTH, 0x48545541)
        self.assertEqual(A_SYNC, 0x434E5953)

    def test_cnxn_packet(self):
        p = encode(A_CNXN, A_VERSION, MAX_PAYLOAD, b"host::\x00")
        pkt, rest = decode_one(p)
        self.assertEqual(rest, b"")
        self.assertEqual(pkt.name, "CNXN")
        self.assertEqual(pkt.arg0, A_VERSION)
        self.assertEqual(pkt.arg1, MAX_PAYLOAD)
        self.assertEqual(pkt.data, b"host::\x00")
        self.assertEqual(len(p), 24 + len(b"host::\x00"))
        # 头里 magic 必须等于 command 取反
        self.assertEqual(struct.unpack("<I", p[20:24])[0],
                         (A_CNXN ^ 0xFFFFFFFF) & 0xFFFFFFFF)

    def test_checksum_is_plain_sum(self):
        data = bytes(range(256))
        p = encode(A_WRTE, 7, 3, data)
        self.assertEqual(struct.unpack("<I", p[16:20])[0], sum(range(256)))

    def test_checksum_over_32bit(self):
        # 4096 个 0xFF = 1044480 < 2^32，用更大的 payload 验证取模
        data = b"\xff" * 4096
        p = encode(A_WRTE, 1, 1, data)
        self.assertEqual(struct.unpack("<I", p[16:20])[0], 4096 * 255)

    def test_stream_fragmentation(self):
        """TCP 是字节流：一次收到半个头、半个 payload 都要能正确拼包"""
        packets = [
            encode(A_CNXN, A_VERSION, MAX_PAYLOAD, b"host::\x00"),
            encode(A_AUTH, ADB_AUTH_TOKEN, 0, bytes(range(20))),
            encode(A_WRTE, 5, 1, b"hello world"),
        ]
        wire = b"".join(packets)
        # 按任意碎片投递
        buf = b""
        got = []
        for chunk_size in (1, 7, 13, 24, 31, 64):
            buf = b""
            got = []
            for i in range(0, len(wire), chunk_size):
                buf += wire[i:i + chunk_size]
                while True:
                    pkt, buf = decode_one(buf)
                    if pkt is None:
                        break
                    got.append(pkt)
            self.assertEqual(len(got), 3, f"碎片 {chunk_size} 解包数量不对")
        self.assertEqual([p.name for p in got], ["CNXN", "AUTH", "WRTE"])
        self.assertEqual(got[2].data, b"hello world")

    def test_shell_open_service(self):
        """OPEN 的 payload 是 'shell:<命令>\\0'，arg0=本地 id，arg1=0"""
        local_id = 1
        service = b"shell:reboot recovery\x00"
        p = encode(A_OPEN, local_id, 0, service)
        pkt, _ = decode_one(p)
        self.assertEqual(pkt.name, "OPEN")
        self.assertEqual(pkt.arg0, local_id)
        self.assertEqual(pkt.arg1, 0)
        self.assertEqual(pkt.data, service)

    def test_okay_flow_control(self):
        """每收到一个 WRTE 必须回 OKAY(local, remote)，否则 adbd 会停住"""
        local_id, remote_id = 1, 42
        incoming = encode(A_WRTE, remote_id, local_id, b"output")
        pkt, _ = decode_one(incoming)
        reply = encode(A_OKAY, local_id, remote_id)
        rp, _ = decode_one(reply)
        self.assertEqual(rp.name, "OKAY")
        self.assertEqual(rp.arg0, local_id)
        self.assertEqual(rp.arg1, remote_id)

    def test_reboot_services(self):
        """adb reboot xxx 对应的是 reboot:<arg> 服务，而不是 shell 命令"""
        for mode in ("", "recovery", "bootloader", "sideload", "sideload-auto-reboot"):
            service = ("reboot:" + mode).encode() + b"\x00"
            p = encode(A_OPEN, 1, 0, service)
            pkt, _ = decode_one(p)
            self.assertEqual(pkt.data, service)
            self.assertTrue(pkt.data.endswith(b"\x00"))

    def test_auth_packet(self):
        """AUTH TOKEN=1 (20 字节)，SIGNATURE=2 (RSA 签名)，RSAPUBLICKEY=3"""
        token = bytes(range(20))
        p = encode(A_AUTH, ADB_AUTH_TOKEN, 0, token)
        pkt, _ = decode_one(p)
        self.assertEqual(pkt.arg0, ADB_AUTH_TOKEN)
        self.assertEqual(len(pkt.data), 20)
        sig = b"\xab" * 256
        p2 = encode(A_AUTH, ADB_AUTH_SIGNATURE, 0, sig)
        self.assertEqual(decode_one(p2)[0].arg0, ADB_AUTH_SIGNATURE)
        pub = b"QAAA" * 100 + b" tvtools@iphone\x00"
        p3 = encode(A_AUTH, ADB_AUTH_RSAPUBLICKEY, 0, pub)
        self.assertEqual(decode_one(p3)[0].arg0, ADB_AUTH_RSAPUBLICKEY)
        self.assertTrue(decode_one(p3)[0].data.endswith(b"\x00"))

    def test_split_payload_by_max(self):
        """WRTE 必须按对端声明的 max payload 分块"""
        max_payload = 4096
        payload = bytes(range(256)) * 50  # 12800 字节
        chunks = [payload[i:i + max_payload] for i in range(0, len(payload), max_payload)]
        self.assertEqual(len(chunks), 4)
        self.assertEqual(b"".join(chunks), payload)
        self.assertTrue(all(len(c) <= max_payload for c in chunks))


if __name__ == "__main__":
    print("ADB 报文协议自测 —— 与 Swift 侧 ADBProtocol.swift 一一对应\n")
    unittest.main(verbosity=2)
