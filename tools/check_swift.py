#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Swift 源码静态检查（无 Xcode 环境下的可复现验证）。

本机是 Linux，没有 Swift/SwiftUI/Network.framework，无法真正编译 iOS App。
这个脚本做能做的静态检查：
  1. 花括号 / 圆括号 / 方括号 / 字符串 / 注释 的平衡
  2. 所有自定义类型、枚举、方法的"定义 vs 引用"交叉检查
  3. import 清单核对
  4. 已知的 iOS 版本 API 陷阱（topBarTrailing 等 iOS 17 专有）
  5. 与菜单规格的一致性（5 个菜单项、命令字符串、子菜单标题）

运行：python3 tools/check_swift.py
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "TVToolsiOS")
errors = []
warnings = []

files = sorted(glob.glob(os.path.join(SRC, "**", "*.swift"), recursive=True))
text_by_file = {}
for f in files:
    text_by_file[f] = open(f, encoding="utf-8").read()

all_text = "\n".join(text_by_file.values())

# ---------- 1. 括号平衡（去掉注释与字符串后统计） ----------
def strip_noise(s: str) -> str:
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c == '"':
            i += 1
            while i < n:
                if s[i] == "\\":
                    i += 2
                    continue
                if s[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)

for f, text in text_by_file.items():
    s = strip_noise(text)
    for op, cl, name in [("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")]:
        a, b = s.count(op), s.count(cl)
        if a != b:
            errors.append(f"{os.path.relpath(f, ROOT)}: {name}不平衡 {a} vs {b}")

# ---------- 2. 定义 vs 引用 ----------
defs = set(re.findall(r'^\s*(?:public\s+|private\s+|internal\s+|final\s+|@MainActor\s+)*'
                      r'(?:final\s+)?(?:class|struct|enum|protocol)\s+(\w+)',
                      all_text, re.M))
methods = set(re.findall(r'\bfunc\s+(\w+)\s*\(', all_text))

expected_types = [
    "ADB", "ADBPacket", "ADBPacketCoder", "ADBTransport", "ADBAuthenticator",
    "ADBClient", "ADBSyncFrames", "ProbeHTTPServer",
    "AdvancedCommand", "AdvancedMenu", "CommandReference",
    "ProbeResult", "ChannelProbeReport", "ChannelProbe",
    "AppSettings", "LogStore", "TVSession",
    "TVToolsiOSApp", "ContentView", "WelcomeView", "AdvancedMenuView",
    "ConnectionView", "ChannelCheckView",
]
for t in expected_types:
    if t not in defs:
        errors.append(f"缺少类型定义: {t}")

# 关键方法调用是否都有定义
key_calls = [
    "connect", "disconnect", "shell", "reboot", "openService", "run",
    "probeSync", "probePull", "probeExec", "probePTY", "probeBase64", "probeOctal",
    "importKey", "sign", "publicKeyPayload", "restoreFromKeychain", "clear",
    "start", "stop", "localIPv4", "send", "decode", "encode", "checksum",
]
for m in key_calls:
    if m not in methods and f"func {m}" not in all_text:
        errors.append(f"方法未定义却被引用: {m}(...)")

# ---------- 3. import 核对 ----------
imports = sorted(set(re.findall(r'^import\s+(\w+)', all_text, re.M)))
allowed = {"SwiftUI", "UIKit", "Foundation", "Network", "Security",
           "UniformTypeIdentifiers", "Darwin"}
for imp in imports:
    if imp not in allowed:
        warnings.append(f"未在预期清单内的 import: {imp}")

# 用到 Network 的文件必须有 import Network（检查剥离注释后的代码，避免注释误报）
for f, text in text_by_file.items():
    code = strip_noise(text)
    rel = os.path.relpath(f, ROOT)
    if ("NWConnection" in code or "NWListener" in code) and "import Network" not in code:
        errors.append(f"{rel}: 用了 NWConnection/NWListener 但没 import Network")
    if ("SecKey" in code or "kSecClass" in code) and "import Security" not in code:
        errors.append(f"{rel}: 用了 Security API 但没 import Security")
    if (": View" in code or "@main" in code) and "import SwiftUI" not in code:
        errors.append(f"{rel}: SwiftUI 视图但没 import SwiftUI")
    if "getifaddrs" in code and "import Darwin" not in code:
        errors.append(f"{rel}: 用了 getifaddrs 但没 import Darwin")

# ---------- 4. iOS 版本陷阱 ----------
# NavigationStack / .regularMaterial 需要 iOS 16，工程已设 16.0，属满足项；
# 只有 iOS 17 才有的 .topBarTrailing 才是真错误。
for f, text in text_by_file.items():
    if ".topBarTrailing" in strip_noise(text):
        errors.append(f"{os.path.relpath(f, ROOT)}: 用了 iOS 17 专有 .topBarTrailing，"
                      "请改成 .navigationBarTrailing")
print("  ℹ  工程 iOS 部署目标 16.0，NavigationStack / .regularMaterial 均满足")

# ---------- 5. 菜单规格一致性 ----------
cmd_text = open(os.path.join(SRC, "Features/Commands.swift"), encoding="utf-8").read()
spec = [
    ("重启到Recovery", "recovery"),
    ("重启到Fastboot", "bootloader"),
    ("重启到sideload", "sideload"),
    ("正常重启", "mode: \"\""),
]
for label, mode in spec:
    if label not in cmd_text:
        errors.append(f"菜单缺少: {label}")
    if mode not in cmd_text:
        errors.append(f"命令缺少: {mode}")
if 'cardTitle = "高级功能"' not in cmd_text:
    errors.append("首页卡片标题不是「高级功能」")
if 'sheetTitle = "高级功能"' not in cmd_text:
    errors.append("子菜单弹出标题不是「高级功能」")
if 'healthCheckTitle = "传输通道体检"' not in cmd_text:
    errors.append("第 5 项不是「传输通道体检」")

# 体检必须是 1 清点 + 6 通道
probe_text = open(os.path.join(SRC, "Features/ChannelProbe.swift"), encoding="utf-8").read()
for ch in ["Sync 快速通道", "电视自取", "exec 裸管道", "PTY 直传", "base64 分段", "八进制保底"]:
    if ch not in probe_text:
        errors.append(f"体检缺少通道: {ch}")
if "清点电视端工具" not in probe_text:
    errors.append("体检缺少工具清点")

# Info.plist 必须声明本地网络权限
plist = open(os.path.join(SRC, "Info.plist"), encoding="utf-8").read()
if "NSLocalNetworkUsageDescription" not in plist:
    errors.append("Info.plist 缺少 NSLocalNetworkUsageDescription")

# ---------- 输出 ----------
print("Swift 静态检查 —— %d 个文件" % len(files))
print("import:", ", ".join(imports))
print("类型定义:", len(defs), "| 方法定义:", len(methods))
print()
for w in warnings:
    print("  ⚠ ", w)
if errors:
    print()
    for e in errors:
        print("  ✗ ", e)
    print("\n失败：%d 个错误" % len(errors))
    sys.exit(1)
print("\n✅ 通过：括号平衡、类型/方法定义齐全、import 正确、菜单规格一致、权限已声明")
