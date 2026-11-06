import SwiftUI
import UIKit

/// 消息气泡：文本 / 图片（内嵌预览，点击看大图）/ 文件（点击下载打开）。
struct BubbleView: View {
    let msg: Message
    let peer: String

    @EnvironmentObject var conn: ChatConnection
    @EnvironmentObject var model: ChatModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if msg.isMine { Spacer(minLength: 60) }
            bubble
            if !msg.isMine { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubble: some View {
        switch msg.msgType {
        case .text:
            HStack {
                Text(msg.content)
                    .font(.body)
                    .foregroundColor(msg.isMine ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .cornerRadius(16)
            }
        case .image:
            imageView
        case .file:
            fileView
        }
    }

    private var bubbleColor: Color {
        msg.isMine ? Color.accentColor : Color(.secondarySystemBackground)
    }

    // MARK: - 图片消息

    private var imageView: some View {
        Group {
            if let fileId = msg.file?.id {
                if let img = model.imageCache[fileId] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 180, maxHeight: 240)
                        .cornerRadius(14)
                        .onTapGesture { previewImage = img }
                } else {
                    placeholder
                        .onAppear {
                            model.loadImage(fileId: fileId) { _ in }
                        }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 180, height: 130)
            ProgressView()
        }
    }

    @State private var previewImage: PlatformImage?

    // MARK: - 文件消息

    @State private var downloading = false
    @State private var openError: String?
    @State private var localFileURL: URL?

    private var fileView: some View {
        Button {
            openFile()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(msg.file?.name ?? "文件")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(fileSizeText)
                        .font(.caption2)
                        .opacity(0.7)
                }
                Spacer(minLength: 8)
                if downloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .padding(12)
            .frame(maxWidth: 260)
            .background(bubbleColor)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .foregroundColor(msg.isMine ? .white : .primary)
        .alert("无法打开文件",
               isPresented: Binding(get: { openError != nil },
                                    set: { if !$0 { openError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
    }

    private var fileSizeText: String {
        let size = msg.file?.size ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - 下载并打开

    private func openFile() {
        guard let fileId = msg.file?.id else { return }
        if let local = localFileURL {
            open(url: local)
            return
        }
        downloading = true
        model.downloadAttachment(fileId: fileId, name: msg.file?.name ?? "file") { url in
            downloading = false
            guard let url else {
                openError = "下载失败，请稍后重试"
                return
            }
            localFileURL = url
            open(url: url)
        }
    }

    private func open(url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if !ok {
                    openError = "系统没有能打开此文件的应用"
                }
            }
        }
    }
}
