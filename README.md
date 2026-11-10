# TVToolsiOS — Android 电视工具箱（iOS 客户端）

把之前那个 Android 版 `tvtools_高级功能版.apk` 的**「高级功能」功能**移植成 iPhone / iPad 原生客户端。
它是 ADB 客户端：通过 Wi-Fi 直连电视的 `5555` 端口，把 `reboot` 等命令发给**电视**，不是发给 iPhone 自己。

> ⚠️ **重要前提**：本机（Linux）没有 macOS / Xcode，**无法编译、签名或真机验证 IPA**。
> 这里交付的是**完整 Xcode 工程源码 + 可复现的自测脚本**，最后一步「编译 + 侧载」必须在你的 Mac 上完成。
> 代码已通过静态检查与 ADB 协议字节级自测，但没有经过 Swift 编译器，第一次 Build 可能需要按报错微调。

---

## 一、功能与菜单树

与 Android 版严格一致：

```
首页
└── 高级功能（卡片，副标题：重启到 Recovery / Fastboot / Sideload、正常重启与传输通道体检）
    └── 高级功能（子菜单，弹出标题 = 高级功能）
        ├── 重启到Recovery    → reboot recovery
        ├── 重启到Fastboot    → reboot bootloader
        ├── 重启到sideload    → reboot sideload
        ├── 正常重启           → reboot
        └── 传输通道体检       → 原七通道体检（逻辑原样保留）
```

**命令等价说明**：你给的是 PC 端 `adb reboot xxx`。iOS App 本身就是 ADB 客户端，
因此直接走 ADB 的 `reboot:<mode>` 服务（等价于写 `sys.powerctl`，与 adb 命令行完全一致），
不再多套一层 `adb shell`。老 adbd 不支持该服务时会自动降级成 shell 的 `reboot <mode>`。

| 菜单项 | PC 命令 | ADB 服务 |
|---|---|---|
| 重启到Recovery | `adb reboot recovery` | `reboot:recovery` |
| 重启到Fastboot | `adb reboot bootloader` | `reboot:bootloader` |
| 重启到sideload | `adb reboot sideload` | `reboot:sideload` |
| 正常重启 | `adb reboot` | `reboot:` |

**传输通道体检**按原版 `TvAdb.probeAll()` 还原：1 次电视端工具清点 + 6 条通道逐条实测（推样本、计时、算 KB/s），
最后按 `probeSummary` 口径给结论：

1. 清点工具（`sh cat nc curl wget base64 stty busybox …` + `busybox --list`）
2. Sync 快速通道（`sync:` 服务，SEND/DATA/DONE 帧）
3. 电视自取（iPhone 起本地 HTTP 服务，电视用 `wget/curl/nc` 反向拉取）
4. exec 裸管道（`exec:`，不依赖电视端工具）
5. PTY 直传（`stty + cat`）
6. base64 分段
7. 八进制保底（2KB 小样）

---

## 二、工程结构

```
TVToolsiOS/
├── README.md                       ← 本文件
├── 编译与侧载指引.md                ← 三种安装路线 + 排错
├── TVToolsiOS.xcodeproj/
│   └── project.pbxproj             ← 完整 Xcode 工程（15 个 Swift 文件全部入工程）
├── TVToolsiOS/
│   ├── Info.plist                  ← NSLocalNetworkUsageDescription / 文件共享
│   ├── Assets.xcassets/
│   ├── App/TVToolsiOSApp.swift     ← @main
│   ├── Views/                      ← ContentView（首页）/ AdvancedMenuView（子菜单）
│   │                                ConnectionView（设置+密钥导入）/ ChannelCheckView（报告）
│   ├── ADB/
│   │   ├── ADBProtocol.swift       ← 24 字节报文头、命令字、编解码、校验和
│   │   ├── ADBTransport.swift      ← NWConnection TCP + 流式拆包
│   │   ├── ADBAuthenticator.swift  ← RSA 密钥导入、SHA1+PKCS1v15 签名、Keychain
│   │   ├── ADBClient.swift         ← CNXN/AUTH 握手状态机、OPEN/OKAY/WRTE/CLSE 流控
│   │   └── ADBSync.swift           ← sync: 协议帧 + 本地 HTTP 服务 + 局域网 IP
│   ├── Features/
│   │   ├── Commands.swift          ← 菜单定义（改这里就能改菜单）
│   │   └── ChannelProbe.swift      ← 七通道体检
│   └── Support/
│       ├── AppSettings.swift       ← @AppStorage
│       ├── LogStore.swift          ← 日志区
│       └── TVSession.swift         ← 全局会话
└── tools/
    ├── adb_protocol_selftest.py    ← ADB 报文字节级自测（10 项）
    ├── check_swift.py              ← Swift 静态检查（括号/类型/import/菜单规格）
    ├── prepare_adbkey.py           ← 把电脑上的 adbkey 转成 App 可导入的 JSON
    └── make_project.py             ← 重新生成 pbxproj（新增文件后重跑）
```

**运行环境**：iOS 16.0+ / Xcode 15+ / Swift 5。依赖全部是系统框架
（SwiftUI、Foundation、Network、Security、UIKit），**没有第三方库、没有 CocoaPods、没有 SPM 依赖**。

---

## 三、三步编译

```bash
# 0. 把整个 TVToolsiOS 目录拷到 Mac（AirDrop / Git / U 盘都行）

# 1. 用 Xcode 打开
open TVToolsiOS.xcodeproj

# 2. 选中 TVToolsiOS target → Signing & Capabilities
#    · Team 选你的 Apple ID（免费账号即可）
#    · Bundle Identifier 改成你自己的，比如 cn.<你的名字>.tvtools
#    · 保持 Automatically manage signing 勾选

# 3. iPhone 用数据线连上 Mac，选真机为 Destination，⌘R 运行
```

模拟器**跑不了**（模拟器访问不到局域网里的电视，且 ADB 是真实 TCP 连接），必须用真机。

---

## 四、使用

1. 电视上打开 **设置 → 账号与安全 → 网络调试（ADB）**（部分固件叫「ADB 调试」/「开发者选项」）。
2. 查电视 IP：**设置 → 关于 → 状态**。
3. iPhone 和电视连**同一个 Wi-Fi**；首次连接会弹「本地网络」权限，选**允许**。
4. App 里点右上角齿轮 → 填 IP（端口默认 `5555`）→ 保存并连接。
5. 首页点「高级功能」→ 弹出子菜单 → 选命令，确认后执行。
6. 「传输通道体检」会跑 1~2 分钟，结果在报告页可复制。

### 关于 USB 调试授权（RSA 认证）

绝大多数电视 / 盒子 `ro.adb.secure=0`，**不需要密钥，直接连上**。
若日志出现「电视要求 USB 调试授权」，二选一：

- **推荐**：导入电脑上已有的 `~/.android/adbkey`（电视很可能早就授权过这把钥匙）
  ```bash
  adb keygen ~/.android/adbkey                # 电脑没有密钥时先生成
  python3 tools/prepare_adbkey.py             # 产出 adbkey_for_ios.json
  ```
  把 JSON AirDrop 到 iPhone → App「连接设置 → 导入 ADB 密钥 JSON」选中它。
  私钥只存本机 Keychain（`ThisDeviceOnly`），不上传、不进 iCloud。
- 或者在电视弹出的「允许 USB 调试」对话框里勾选**一律允许**并确认。

> 为什么不让 App 自己生成密钥：`adbkey.pub` 不是标准 PEM，是 Android 自定义的
> `RSAPublicKey` 结构（含 `n0inv` / `rr` 两个 Montgomery 参数），需要大数运算。
> iOS 侧重新实现风险高，所以采用「导入现成密钥」这条更稳的路。

---

## 五、与 Android 版的差异（重要）

| 维度 | Android 版 | iOS 版 |
|---|---|---|
| 运行平台 | Android 手机 | iPhone / iPad (iOS 16+) |
| ADB 实现 | 内置 adblib | 纯 Swift 实现 ADB 报文协议（Network.framework） |
| 命令目标 | 同一台 Android 电视 | 相同，`reboot` 等命令发给电视 |
| 打包 | APK，自签 keystore | IPA，必须 Apple 证书 + provisioning profile |
| 分发 | 直接发 APK 装 | 侧载（Xcode/AltStore/Sideloadly，免费账号 7 天过期）或 TestFlight |
| App Store | 不涉及 | 上不了架（这类控制设备并重启的工具会被拒） |
| 编译环境 | Linux 全流程完成 | **必须 macOS + Xcode** |
| 权限 | 6 个普通权限 | 需 `NSLocalNetworkUsageDescription` 并在首次访问局域网时授权 |
| 远程清单 | 有硬编码 `catalog.json`（无验签，中高风险） | **不含**，本工程不联网拉任何清单 |
| 内嵌 APK | 3 个 Aerial 桌面（公开 debug 证书） | **不含**，本工程不推送 / 安装任何 APK |

另外，本工程**只移植了「高级功能」这一块**（连接 + 5 项菜单 + 体检）。
Android 版里的「卸载预装 / 装 Aerial 桌面 / 恢复已卸载应用 / 桌面接管」等**没有移植**——
那些功能依赖手机本地 APK 文件与 Android 特有的 `pm`/`settings` 能力，
且正是上一份分析报告里风险最高的部分。需要的话可以按 `Features/` 的结构继续扩展。

---

## 六、已知限制（请先看）

- **未经 Swift 编译器验证**：本机是 Linux，没有 Xcode。静态检查（`check_swift.py`）能覆盖括号、
  类型定义、import、菜单规格，但无法替代 `swiftc`。第一次 Build 若有报错，基本是 API 签名细节，按 Xcode 提示改即可。
- **传输通道体检的 6 条通道是"能跑的实现"，不是逐字节复刻原版**：原版依赖 Android 手机端的
  `HttpPush` / `syncWithWatchdog` / PTY 等具体实现，iOS 版用等价的 ADB 服务重新实现，
  结论口径一致，但绝对速度数值会受 iPhone 网络栈影响，不必与 Android 版逐项对齐。
- **`reboot sideload` 依赖电视支持**：部分 ROM 没有 sideload 分区，命令发出后可能只是普通重启。
- **重启后连接必断**：属正常现象，App 已把它当成功处理，不会误报错误。
- **Android 11+ 无线调试配对码新协议（TLS）不支持**：本工程只走 `5555` 端口直连，
  和原版 Android App 一样。若电视只提供配对码方式，需要在电视开发者选项里开「网络调试(旧)」或先用电脑 `adb tcpip 5555`。
- **免费 Apple ID 签的 App 7 天过期**，到期需重新 ⌘R；想长期用建议付费开发者账号或 TestFlight。

---

## 七、自测（可在 Linux / Mac / Windows 上跑）

```bash
cd TVToolsiOS
python3 tools/adb_protocol_selftest.py    # ADB 报文编解码 10 项，OK
python3 tools/check_swift.py              # Swift 静态检查，通过
python3 tools/make_project.py             # 重新生成 pbxproj
python3 tools/prepare_adbkey.py           # 生成密钥导入 JSON（需 ~/.android/adbkey）
```

三项自测已在本机跑通：协议 10/10、静态检查通过、pbxproj 53 个 ID 引用全部有定义、15 个 Swift 文件全部入工程。
