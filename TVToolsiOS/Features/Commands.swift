import Foundation

// MARK: - 「高级功能」菜单定义
//
// 与 Android 版 tvtools_高级功能版.apk 的菜单树严格一致：
//
//   首页
//   └── 高级功能（卡片）
//       └── 高级功能（子菜单，弹出标题）
//           ├── 重启到Recovery   -> reboot recovery
//           ├── 重启到Fastboot   -> reboot bootloader
//           ├── 重启到sideload   -> reboot sideload
//           ├── 正常重启          -> reboot
//           └── 传输通道体检      -> 原七通道体检（逻辑原样保留）
//
// 注意命令等价转换：用户给的是 PC 端 `adb reboot xxx`；
// iOS App 本身就是 ADB 客户端，因此直接用 ADB 的 `reboot:<mode>` 服务，
// 这与 adb 命令行完全等价（写 sys.powerctl），不再多套一层 `adb shell`。
// 老 adbd 不支持 reboot: 服务时，ADBClient 会自动降级成 shell 的 `reboot <mode>`。

struct AdvancedCommand: Identifiable {
    let id = UUID()
    let label: String
    let subtitle: String
    let mode: String          // reboot:<mode> 的 mode；空串表示正常重启
    let symbol: String        // SF Symbol
    let destructive: Bool
}

enum AdvancedMenu {
    static let cardTitle = "高级功能"
    static let cardSubtitle = "重启到 Recovery / Fastboot / Sideload、正常重启与传输通道体检"
    static let sheetTitle = "高级功能"     // 子菜单弹出标题（用户指定与卡片同名）

    static let commands: [AdvancedCommand] = [
        AdvancedCommand(
            label: "重启到Recovery",
            subtitle: "进入恢复模式，用于卡刷 / 清除数据",
            mode: "recovery",
            symbol: "arrow.clockwise.circle",
            destructive: true
        ),
        AdvancedCommand(
            label: "重启到Fastboot",
            subtitle: "进入 bootloader，用于线刷 / 解锁",
            mode: "bootloader",
            symbol: "bolt.circle",
            destructive: true
        ),
        AdvancedCommand(
            label: "重启到sideload",
            subtitle: "进入 ADB sideload 刷机模式",
            mode: "sideload",
            symbol: "square.and.arrow.down",
            destructive: true
        ),
        AdvancedCommand(
            label: "正常重启",
            subtitle: "普通重启，回到系统",
            mode: "",
            symbol: "restart.circle",
            destructive: false
        ),
    ]

    static let healthCheckTitle = "传输通道体检"
    static let healthCheckSubtitle = "七条通道一次测完，看清空这台电视能走哪条"
}

// MARK: - 与 Android 版逐字对齐的 PC 端命令（仅用于文档/日志展示）

enum CommandReference {
    static let mapping: [(label: String, pcCommand: String, adbService: String)] = [
        ("重启到Recovery",  "adb reboot recovery",   "reboot:recovery"),
        ("重启到Fastboot",  "adb reboot bootloader", "reboot:bootloader"),
        ("重启到sideload",  "adb reboot sideload",   "reboot:sideload"),
        ("正常重启",        "adb reboot",            "reboot:"),
    ]
}
