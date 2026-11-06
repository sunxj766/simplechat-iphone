import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 用 PHPickerViewController 选照片（不需要相册权限），
/// 回调图片 JPEG/PNG 数据与 mime。
struct PhotoPicker: UIViewControllerRepresentable {
    var onPicked: (Data, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (Data, String) -> Void
        init(onPicked: @escaping (Data, String) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            let isPNG = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
            let type: UTType = isPNG ? .png : .jpeg
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                if let data {
                    DispatchQueue.main.async {
                        onPicked(data, type == .png ? "image/png" : "image/jpeg")
                    }
                } else {
                    // 兜底：解码后重编码
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        guard let image = object as? UIImage,
                              let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
                        DispatchQueue.main.async {
                            onPicked(jpeg, "image/jpeg")
                        }
                    }
                }
            }
        }
    }
}

/// 文件选择器（UIDocumentPicker，无需存储权限）
struct FilePicker: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPicked(url)
            }
        }
    }
}

/// 图片大图预览（点击任意处关闭）
struct ImageViewer: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ImageViewer.Content(image: image)
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
            }
        }
    }
}

private extension ImageViewer {
    struct Content: View {
        let image: PlatformImage
        var body: some View {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}
