import SwiftUI
import UniformTypeIdentifiers

// MARK: - 连接设置 + ADB 密钥导入

struct ConnectionView: View {
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss

    @State private var hostText: String = ""
    @State private var portText: String = ""
    @State private var showImporter = false
    @State private var importMessage = ""
    @State private var keyStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("电视地址") {
                    TextField("IP 地址，如 192.168.1.100", text: $hostText)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("电视上：设置 → 关于 → 状态 可查看本机 IP")
                }

                Section {
                    Button {
                        session.settings.host = hostText.trimmingCharacters(in: .whitespaces)
                        session.settings.port = Int(portText) ?? 5555
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            await session.connect()
                        }
                    } label: {
                        Label("保存并连接", systemImage: "cable.connector")
                    }
                    .disabled(hostText.isEmpty)
                }

                Section("ADB 密钥（可选）") {
                    Text("绝大多数电视/盒子不需要认证，可直接连接。若电视要求「允许 USB 调试」，导入电脑上已有的 ~/.android/adbkey 即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(keyStatus.isEmpty
                         ? (session.client.authenticator.hasKey ? "已导入密钥" : "未导入密钥")
                         : keyStatus)
                        .font(.caption.monospaced())

                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 ADB 密钥 JSON", systemImage: "key.fill")
                    }

                    if session.client.authenticator.hasKey {
                        Button("清除密钥", role: .destructive) {
                            session.client.authenticator.clear()
                            keyStatus = "已清除"
                        }
                    }
                } header: {
                    Text("RSA 认证")
                } footer: {
                    Text("在 Mac 上执行 python3 tools/prepare_adbkey.py 生成 JSON，AirDrop 到 iPhone 后在此选择。私钥只存本机 Keychain，不上传、不进 iCloud。")
                }

                Section("命令对照") {
                    ForEach(CommandReference.mapping, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.subheadline)
                            Text("\(item.pcCommand)  →  \(item.adbService)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("连接设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                hostText = session.settings.host
                portText = String(session.settings.port)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                keyStatus = "无法读取所选文件"; return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let der = json["pkcs1_der_base64"] as? String,
                  let pub = json["adbkey_pub"] as? String else {
                keyStatus = "JSON 格式不对（应含 pkcs1_der_base64 / adbkey_pub）"; return
            }
            try session.client.authenticator.importKey(pkcs1DERBase64: der, pubText: pub)
            keyStatus = "✓ 已导入 \(session.client.authenticator.fingerprint)"
            session.log.append("· 已导入 ADB 密钥 \(session.client.authenticator.fingerprint)")
        } catch {
            keyStatus = "导入失败：\(error.localizedDescription)"
        }
    }
}
