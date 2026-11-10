import Foundation
import SwiftUI

// MARK: - 连接设置（持久化）

final class AppSettings: ObservableObject {
    private enum Key {
        static let host = "tvtools.host"
        static let port = "tvtools.port"
        static let confirmedRisk = "tvtools.confirmedRisk"
    }

    @AppStorage(Key.host) var host: String = "192.168.1.100"
    @AppStorage(Key.port) var port: Int = 5555
    @AppStorage(Key.confirmedRisk) var confirmedRisk: Bool = false

    var portValue: UInt16 {
        get { UInt16(clamping: port) }
        set { port = Int(newValue) }
    }
}
