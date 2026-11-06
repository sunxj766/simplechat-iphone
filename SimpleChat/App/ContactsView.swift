import SwiftUI

/// 联系人列表：REST /api/users 10 秒轮询 + presence 实时在线状态 + 未读角标。
struct ContactsView: View {
    @EnvironmentObject var conn: ChatConnection
    @EnvironmentObject var model: ChatModel

    @State private var users: [Contact] = []
    @State private var errorMessage: String?
    private let pollInterval: TimeInterval = 10

    var body: some View {
        NavigationStack {
            List {
                if let err = errorMessage {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ForEach(contacts) { c in
                    NavigationLink(value: c.username) {
                        row(c)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Session.shared.username.isEmpty ? conn.username : Session.shared.username)
            .navigationDestination(for: String.self) { peer in
                ChatView(peer: peer)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 连接状态
                    HStack(spacing: 4) {
                        Circle()
                            .fill(conn.isReachable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(conn.isReachable ? "在线" : "重连中")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .onAppear {
            Session.shared.username = conn.username
            fetchUsers()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
        .refreshable {
            fetchUsers()
        }
    }

    // MARK: - 子视图

    private var contacts: [Contact] {
        var list = users
        // presence 修正在线状态
        for i in list.indices {
            list[i].online = conn.onlineUsers.contains(list[i].username)
        }
        // 未读修正
        for i in list.indices {
            list[i].unread = model.unreadCounts[list[i].username] ?? 0
        }
        return list
    }

    private func row(_ c: Contact) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(c.online ? Color.green.opacity(0.15) : Color(.systemGray5))
                    .frame(width: 40, height: 40)
                Text(String(c.displayName.prefix(1)))
                    .font(.headline)
                    .foregroundColor(c.online ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName)
                    .font(.body)
                Text(c.online ? "在线" : "离线")
                    .font(.caption)
                    .foregroundColor(c.online ? .green : .secondary)
            }
            Spacer()
            if c.unread > 0 {
                Text("\(c.unread)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数据

    private func fetchUsers() {
        guard let url = URL(string: "\(conn.httpBase)/api/users") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["users"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                let me = conn.username
                self.users = arr.compactMap { u in
                    guard let name = u["username"] as? String, name != me else { return nil }
                    return Contact(username: name,
                                   nickname: u["nickname"] as? String ?? "",
                                   online: conn.onlineUsers.contains(name),
                                   unread: model.unreadCounts[name] ?? 0)
                }
            }
        }.resume()
    }

    @State private var pollTimer: Timer?

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: pollInterval, repeats: true) { _ in
            fetchUsers()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func logout() {
        stopPolling()
        model.conversations.removeAll()
        model.imageCache.removeAll()
        model.unreadCounts.removeAll()
        conn.logout()
    }
}
