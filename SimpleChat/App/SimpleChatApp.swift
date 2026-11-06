import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

// MARK: - 应用入口

@main
struct SimpleChatApp: App {
    @StateObject private var conn = ChatConnection()
    @StateObject private var model = ChatModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(conn)
                .environmentObject(model)
                .onAppear {
                    model.bind(conn: conn)
                }
        }
    }
}

// MARK: - 按连接状态切换页面

struct RootView: View {
    @EnvironmentObject var conn: ChatConnection

    var body: some View {
        switch conn.stage {
        case .login, .connecting:
            LoginView()
        case .contacts:
            ContactsView()
        }
    }
}
