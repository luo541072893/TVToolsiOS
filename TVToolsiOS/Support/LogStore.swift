import Foundation
import SwiftUI

// MARK: - 日志区（对齐 Android 版首页底部的日志面板）

final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 400

    func append(_ text: String) {
        lock.lock()
        lines.append(text)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
    }

    var text: String { lines.joined(separator: "\n") }
}
