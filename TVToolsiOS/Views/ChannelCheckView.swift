import SwiftUI
import UIKit

// MARK: - 传输通道体检报告
// 对齐 Android 版 showReportDialog / probeSummary 的分组与文案

struct ChannelCheckView: View {
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let report = session.channelReport {
                    Section("结论") {
                        Text(report.summary)
                            .font(.subheadline)
                        if report.tooSlowForAPK {
                            Label("无线链路较慢，建议用 U 盘装 APK 或改有线连接",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("设备与连接") {
                        row("目标电视", "\(session.settings.host):\(session.settings.port)")
                        row("电视端工具", report.tools.isEmpty
                            ? "未读到" : report.tools.joined(separator: " "))
                    }

                    Section("通道实测") {
                        ForEach(report.results) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: r.available
                                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(r.available ? .green : .secondary)
                                    Text(r.name).font(.subheadline)
                                    Spacer()
                                    if r.available {
                                        Text(String(format: "%.0f KB/s", r.kbPerSecond))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !r.note.isEmpty {
                                    Text(r.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = reportText(report)
                        } label: {
                            Label("复制完整报告", systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("正在逐条测试通道…").font(.subheadline)
                        }
                        Text("共 1 次工具清点 + 6 条通道，每条都会推一份测试样本并计时。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("电视体检报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func reportText(_ r: ChannelProbeReport) -> String {
        var lines = ["TV桌面工具 · 传输通道体检报告",
                     "目标：\(session.settings.host):\(session.settings.port)", "",
                     "电视端工具：\(r.tools.joined(separator: " "))", ""]
        lines += r.results.map { $0.line }
        lines += ["", r.summary]
        return lines.joined(separator: "\n")
    }
}
