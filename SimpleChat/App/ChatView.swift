import SwiftUI

/// 聊天页：消息气泡（文本/图片/文件）、图片/文件发送、清空按钮、正在输入提示。
struct ChatView: View {
    let peer: String

    @EnvironmentObject var conn: ChatConnection
    @EnvironmentObject var model: ChatModel

    @State private var input = ""
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showClearConfirm = false
    @State private var sendFailedAlert: String?
    @State private var previewImage: PlatformImage?

    var body: some View {
        VStack(spacing: 0) {
            // 断线横幅
            if let banner = conn.banner {
                Text(banner)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(Color.orange.opacity(0.15))
            }

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        let list = model.conversations[peer] ?? []
                        if list.isEmpty {
                            Text("暂无消息，发送第一条吧")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        }
                        ForEach(list) { msg in
                            BubbleView(msg: msg, peer: peer)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: model.conversations[peer]?.last?.id) { _ in
                    if let last = model.conversations[peer]?.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let last = model.conversations[peer]?.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // 正在输入提示
            if model.typingPeers.contains(peer) {
                HStack {
                    Text("对方正在输入…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            // 输入区
            HStack(spacing: 10) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.title3)
                }

                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }

                TextField("发消息…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(trimmedInput.isEmpty)
            }
            .padding(10)
            .background(Color(.systemBackground))
        }
        .navigationTitle(peer)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空聊天记录", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "将清空与 \(peer) 的所有历史记录（包括聊天消息与文件，双方均不可见），是否继续？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                model.clearHistory(peer: peer)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { data, mime in
                sendImage(data: data, mime: mime)
            }
        }
        .sheet(isPresented: $showFilePicker) {
            FilePicker { url in
                sendFile(url: url)
            }
        }
        .alert("发送失败",
               isPresented: Binding(get: { sendFailedAlert != nil },
                                    set: { if !$0 { sendFailedAlert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sendFailedAlert ?? "")
        }
        .fullScreenCover(isPresented: Binding(get: { previewImage != nil },
                                              set: { if !$0 { previewImage = nil } })) {
            ImageViewer(image: previewImage ?? PlatformImage())
        }
        .onAppear {
            model.setCurrentPeer(peer)
            model.loadHistory(peer: peer)
        }
        .onDisappear {
            model.setCurrentPeer(nil)
        }
    }

    // MARK: - 发送

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        input = ""
        model.appendLocal(peer: peer, content: text, type: .text)
    }

    private func sendImage(data: Data, mime: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(mime == "image/png" ? "png" : "jpg")
        do {
            try data.write(to: tmp)
        } catch {
            sendFailedAlert = "图片写入临时目录失败"
            return
        }
        uploadAndSend(url: tmp, mime: mime)
    }

    private func sendFile(url: URL) {
        uploadAndSend(url: url, mime: HttpFileTransfer.mimeForExtension(url.lastPathComponent))
    }

    /// 上传后发 ws 信令（上传在后台线程，成功回主线程上屏）
    private func uploadAndSend(url: URL, mime: String) {
        guard conn.isReachable, !conn.fileToken.isEmpty else {
            sendFailedAlert = "当前未连接服务器"
            return
        }
        let base = conn.httpBase
        let token = conn.fileToken
        let to = peer

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try HttpFileTransfer.upload(
                    url: URL(string: base + "/api/upload")!,
                    fileUrl: url, token: token, to: to)
                DispatchQueue.main.async {
                    model.appendLocal(
                        peer: to,
                        content: "",
                        file: .init(id: result.fileId, name: result.name,
                                    size: result.size, mime: result.mime),
                        type: result.mime.hasPrefix("image/") ? .image : .file)
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                DispatchQueue.main.async {
                    sendFailedAlert = error.localizedDescription
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
