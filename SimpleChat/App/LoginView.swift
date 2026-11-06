import SwiftUI

/// 登录页：服务器地址/端口在页面上填写，通信密钥内置（与服务器一致）。
struct LoginView: View {
    @EnvironmentObject var conn: ChatConnection
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var port = ""
    @State private var showPassword = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo
            Image(systemName: "message.circle.fill")
                .resizable()
                .frame(width: 88, height: 88)
                .foregroundColor(.accentColor)
                .padding(.bottom, 4)

            Text("企信通")
                .font(.largeTitle.bold())

            Text("安全即时通讯")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 14) {
                TextField("服务器地址", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                HStack(spacing: 8) {
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                }

                TextField("用户名", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                HStack {
                    Group {
                        if showPassword {
                            TextField("密码", text: $password)
                        } else {
                            SecureField("密码", text: $password)
                        }
                    }
                    .textContentType(.password)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

                if let err = conn.loginError {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                if conn.stage == .connecting {
                    ProgressView("正在连接服务器…")
                        .padding(.vertical, 4)
                }

                Button {
                    let host = server.trimmingCharacters(in: .whitespaces)
                    let p = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
                    guard !host.isEmpty, p > 0, p <= 65535 else {
                        conn.loginError = "请填写有效的服务器地址和端口"
                        return
                    }
                    conn.updateServer(host: host, port: p)
                    conn.login(username: username, password: password)
                } label: {
                    Text("登 录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty
                          || server.trimmingCharacters(in: .whitespaces).isEmpty
                          || conn.stage == .connecting)
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .onAppear {
            // 记住的用户名与上次成功登录的服务器地址/端口自动填充（首次为空）
            username = conn.username
            if !conn.host.isEmpty { server = conn.host }
            if conn.port > 0 { port = String(conn.port) }
        }
    }
}
