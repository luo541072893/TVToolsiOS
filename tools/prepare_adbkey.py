#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把电脑上的 ADB 密钥（~/.android/adbkey + adbkey.pub）转成 iOS App 可导入的 JSON。

为什么需要转换：
  · Android 的 adbkey 是 PEM 格式的 PKCS#8 私钥；iOS 的 SecKeyCreateWithData
    对 PKCS#8 支持不稳定，但能稳定导入 PKCS#1 "RSA PRIVATE KEY" 的裸 DER。
  · adbkey.pub 是 Android 自定义二进制结构，iOS 端无法重新生成，
    所以必须把原文件整个搬过来，原样发给 adbd。

用法：
  python3 tools/prepare_adbkey.py                      # 自动找 ~/.android/adbkey*
  python3 tools/prepare_adbkey.py -k /path/adbkey -p /path/adbkey.pub
  python3 tools/prepare_adbkey.py --make              # 没有密钥时现场生成一对（需 openssl）

产出：把打印出来的 JSON 通过 AirDrop / 文件 App / iCloud 传到 iPhone，
      在 App 的「连接设置 → 导入 ADB 密钥」里选择该文件即可。

若电脑还没有密钥：
  adb keygen ~/.android/adbkey      # 或任意执行一次 `adb devices` 自动生成
  python3 tools/prepare_adbkey.py --make
"""
import argparse
import base64
import json
import os
import subprocess
import sys


# ---------- 极简 DER TLV 解析（只解析到需要的深度，纯标准库） ----------
def read_tlv(data: bytes, pos: int = 0):
    """返回 (tag, value_bytes, next_pos)"""
    tag = data[pos]
    pos += 1
    length = data[pos]
    pos += 1
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(data[pos:pos + n], "big")
        pos += n
    value = data[pos:pos + length]
    return tag, value, pos + length


def pkcs8_to_pkcs1_der(der: bytes) -> bytes:
    """从 PKCS#8 PrivateKeyInfo 里剥出内层的 PKCS#1 RSAPrivateKey DER。

    注意：OCTET STRING 的内容本身就是一份完整的 PKCS#1 DER
    （以 30 82 ... SEQUENCE 开头），直接返回即可，不能再包一层 SEQUENCE。
    """
    # PrivateKeyInfo ::= SEQUENCE { version INTEGER, alg SEQUENCE, key OCTET STRING }
    tag, body, _ = read_tlv(der, 0)
    if tag != 0x30:
        raise ValueError("私钥不是 DER SEQUENCE")
    pos = 0
    _, _, pos = read_tlv(body, pos)          # version
    _, _, pos = read_tlv(body, pos)          # algorithm identifier
    tag, inner, _ = read_tlv(body, pos)      # privateKey OCTET STRING
    if tag != 0x04:
        raise ValueError("PKCS#8 里没找到 OCTET STRING 私钥")
    if inner and inner[0] != 0x30:
        raise ValueError("OCTET STRING 里不是 PKCS#1 SEQUENCE")
    return inner


def looks_like_pkcs1(der: bytes) -> bool:
    """PKCS#1 RSAPrivateKey 的第一个 INTEGER 是 version=0；
       PKCS#8 的第一个 INTEGER 也是 0，但第二个元素是 SEQUENCE，
       PKCS#1 的第二个元素是 INTEGER(modulus)。用这点区分。"""
    try:
        tag, body, _ = read_tlv(der, 0)
        if tag != 0x30:
            return False
        _, _, pos = read_tlv(body, 0)
        tag2, _, _ = read_tlv(body, pos)
        return tag2 == 0x02   # INTEGER = modulus
    except Exception:
        return False


def load_pem(path: str) -> bytes:
    text = open(path, "r", encoding="utf-8", errors="ignore").read()
    lines = [l.strip() for l in text.splitlines()
             if l.strip() and not l.startswith("-----")]
    return base64.b64decode("".join(lines))


def make_pair(keydir: str):
    """用 openssl 现场生成一对 adb 兼容密钥"""
    os.makedirs(keydir, exist_ok=True)
    key = os.path.join(keydir, "adbkey")
    subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # adbkey.pub 需要 Android 自定义格式；这里借用 adb 自己来生成最稳妥
    pub = key + ".pub"
    if os.path.exists(pub):
        os.remove(pub)
    try:
        subprocess.run(["adb", "keygen", key], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("⚠ 未找到 adb 命令，无法生成 adbkey.pub。", file=sys.stderr)
        print("  请安装 Android platform-tools 后执行：adb keygen ~/.android/adbkey", file=sys.stderr)
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description="生成 iOS App 可导入的 ADB 密钥 JSON")
    ap.add_argument("-k", "--key", default=os.path.expanduser("~/.android/adbkey"))
    ap.add_argument("-p", "--pub", default=None)
    ap.add_argument("-o", "--out", default="adbkey_for_ios.json")
    ap.add_argument("--make", action="store_true", help="没有密钥时现场生成一对")
    args = ap.parse_args()

    if args.make:
        make_pair(os.path.dirname(args.key) or ".")

    pub_path = args.pub or (args.key + ".pub")
    if not os.path.exists(args.key) or not os.path.exists(pub_path):
        print("找不到密钥文件：", args.key, "/", pub_path, file=sys.stderr)
        print("提示：执行 `adb keygen ~/.android/adbkey`，或用 --make 生成。", file=sys.stderr)
        sys.exit(1)

    der = load_pem(args.key)
    pkcs1 = der if looks_like_pkcs1(der) else pkcs8_to_pkcs1_der(der)
    if not looks_like_pkcs1(pkcs1):
        print("⚠ 私钥格式无法识别，请确认是 2048-bit RSA 私钥。", file=sys.stderr)
        sys.exit(1)

    pub_text = open(pub_path, "r", encoding="utf-8", errors="ignore").read().strip()
    if " " not in pub_text:
        pub_text += " tvtools@iphone"   # adbkey.pub 允许任意 user@host 后缀

    payload = {
        "_comment": "由 prepare_adbkey.py 生成；在 iPhone 上用 TVToolsiOS 的「导入 ADB 密钥」选择本文件",
        "pkcs1_der_base64": base64.b64encode(pkcs1).decode("ascii"),
        "adbkey_pub": pub_text,
        "bits": 2048,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print("✅ 已生成", os.path.abspath(args.out))
    print("   PKCS#1 DER 长度:", len(pkcs1), "字节")
    print("   adbkey.pub 前 40 字符:", pub_text[:40] + "...")
    print("\n把这个 JSON 文件 AirDrop / 存到「文件」App，然后在 iPhone 上打开 TVToolsiOS →")
    print("「连接设置 → 导入 ADB 密钥」选中它即可。")


if __name__ == "__main__":
    main()
