---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '8c274168-66a6-4db9-a20f-c4eba0df0447'
  PropagateID: '8c274168-66a6-4db9-a20f-c4eba0df0447'
  ReservedCode1: 'cb33afe4-0370-495c-9f82-087f8bea7fe2'
  ReservedCode2: 'cb33afe4-0370-495c-9f82-087f8bea7fe2'
---

# 企信通 iOS 客户端（SimpleChat for iOS）

与自建服务器配套的 iPhone/iPad 客户端，功能与安卓版对齐：

- 登录（通信密钥已内置；服务器地址/端口在登录页填写，首次为空，填过会记住）
- 实时收发文本消息、正在输入提示、已读回执、未读角标
- 图片/任意文件发送（单文件上限 50MB），图片气泡内嵌预览、点击看大图
- AES-256-GCM 传输加密（与服务器/安卓/Windows 端互通）
- 聊天记录只存内存不落盘（退出即消失），历史从服务器拉取
- 聊天页右上角菜单「清空聊天记录」（删除双方服务器历史）
- 断线自动重连（1s→60s 指数退避）、重连后自动恢复会话

技术：SwiftUI + URLSessionWebSocketTask + CryptoKit，**零第三方依赖**。

---

## 为什么需要"云端编译"

苹果规定 iOS 应用必须用 macOS 上的 Xcode 编译。没有 Mac 时可以用 **GitHub Actions**（免费云服务器，每月 2000 分钟免费额度，公开仓库不限时）在云端 Mac 上代为编译，产出 IPA 文件后再用 Windows 上的免费工具签名安装到 iPhone。

整体流程：**上传工程到 GitHub → 云端自动编译出 IPA → 下载 IPA → Windows 上用 Sideloadly + 您的 Apple ID 签名 → 装进 iPhone**。

## 一、上传工程到 GitHub（约 10 分钟）

1. 注册/登录 [github.com](https://github.com)
2. 点右上角 **+** → **New repository**，名称随意（如 `simplechat-ios`），选 **Public**（公开仓库 Actions 无限免费），不要勾选任何初始化选项，点 **Create repository**
3. 在仓库页面点 **uploading an existing file**（上传现有文件）
4. 把本目录（`ios/`）下的**全部内容**拖进上传区，注意结构必须是：
   ```
   仓库根/
   ├── .github/workflows/build.yml   ← 注意 .github 是隐藏文件夹，务必确认已上传
   ├── project.yml
   └── SimpleChat/                   ← Swift 源码与资源
   ```
   > Windows 资源管理器默认不显示隐藏文件夹。上传前先在「查看」里勾选「隐藏的项目」，确保 `.github` 文件夹一起选中上传；如果漏传，云编译不会运行。
5. 填写提交说明（如 `init`），点 **Commit changes**，等待上传完成
6. 上传完成后，仓库的 **Actions** 标签页会自动出现一次运行，约 5-8 分钟后变绿 ✓
7. 进入该次运行页面，底部 **Artifacts** 下载 **SimpleChat-unsigned-ipa**，解压得到 `SimpleChat-unsigned.ipa`

> 提示：以后改了代码想重新编译，把 `ios` 目录里的文件重新上传覆盖，Actions 会自动重跑。

## 二、用 Sideloadly 签名并安装到 iPhone（Windows，约 15 分钟）

1. 电脑安装 [iTunes](https://www.apple.com/itunes/)（官方版，提供驱动；装完不用打开）
2. 安装 [Sideloadly](https://sideloadly.io)（Windows 版）
3. 手机用数据线连电脑，首次连接点手机上的"信任"
4. 打开 Sideloadly：
   - **IPA**：选择下载的 `SimpleChat-unsigned.ipa`
   - **Apple ID**：填您自己的 Apple ID（用于免费签名）
   - **Password**：Apple ID 密码（建议到 appleid.apple.com 申请"应用专用密码"更安全）
   - 其他选项默认，点 **Start**
5. 等待签名完成，iPhone 上出现「企信通」图标
6. iPhone 上：**设置 → 通用 → VPN 与设备管理**，找到您的 Apple ID，点**信任**
7. 打开 App 即可使用

### 免费签名的限制（苹果规定，无法绕过）

- 签名有效期 **7 天**，到期后 App 打不开，需数据线连电脑用 Sideloadly 重新签一次（数据不丢）
- 每个 Apple ID 最多同时装 **3 个**自签应用
- 想摆脱 7 天限制：加入苹果开发者计划（688 元/年）或使用 AltStore/PsideStore 定期自动续签

## 附一：用 Mac + Xcode 本机编译（替代第一、二节）

有 Mac 时流程更简单：拷贝工程到 Mac → 生成 Xcode 工程 → Xcode 真机运行，**不需要 GitHub、不需要 Sideloadly**。

### 1. 准备（一次性）

- Mac 系统要求 macOS 13.5+，从 **App Store 免费安装 Xcode**（约 12GB，首次打开会提示安装 iOS 组件，同意即可）
- 安装 [Homebrew](https://brew.sh)（Mac 的包管理器），然后把工程生成工具 XcodeGen 装上：
  ```bash
  brew install xcodegen
  ```
- 把整个 `ios` 文件夹拷到 Mac（U盘 / 网盘 / 微信传文件均可；注意包含隐藏的 `.github` 文件夹也无妨，不影响）

### 2. 生成并打开 Xcode 工程

终端（"终端"App）执行：

```bash
cd 拷贝过去的ios目录
xcodegen generate        # 生成 SimpleChat.xcodeproj
open SimpleChat.xcodeproj
```

### 3A. 直接真机运行（推荐，免费 Apple ID 即可）

1. Xcode 菜单 **Xcode → Settings → Accounts → +** 登录您的 Apple ID
2. 左侧选中蓝色工程图标 → TARGETS 选 SimpleChat → **Signing & Capabilities** 标签：
   - **Team** 选您的 *Personal Team*
   - **Bundle Identifier** 改成一个独一无二的值（如 `com.你的名字.simplechat01`；默认值可能已被占用导致签名失败）
3. iPhone 用数据线连 Mac，手机上点"信任"；Xcode 顶部设备栏选中您的 iPhone（首次需在 Xcode 里等它"为开发做准备"完成）
4. 点左上角 **▶ 运行**，App 自动安装并打开
5. 首次运行如提示"不受信任的开发者"：iPhone **设置 → 通用 → VPN与设备管理** → 信任您的开发者证书

> 免费 Apple ID 签名同样 **7 天有效**，到期后连 Mac 再按一次 ▶ 即可续期（数据不丢）。想彻底去掉限制需加入苹果开发者计划（688 元/年）。

### 3B. 导出 IPA 安装包（需付费开发者账号，688 元/年）

1. Xcode 顶部设备选 **Any iOS Device (arm64)**
2. 菜单 **Product → Archive**，完成后弹出 Organizer
3. **Distribute App → Ad Hoc**（需先在开发者后台登记测试设备的 UDID）或 **App Store Connect / TestFlight**
4. 导出的 IPA 可发给任何已登记的 iPhone 直接安装，签名一年有效

### 4. 修改代码与重新编译

- 源码在 `SimpleChat/` 目录，Xcode 里直接改，改完按 ▶ 即可
- 若新增/删除了源文件，无需手动调整，重新跑一次 `xcodegen generate` 即可刷新工程
- 服务器配置（地址/端口/密钥）在 `SimpleChat/Core/ChatConnection.swift` 顶部的三个 `default*` 常量

## 三、使用说明

- 登录：填服务器地址/端口 + 服务器上已建好的账号（管理员用 `--adduser` 创建）；地址端口下次启动自动带出
- 联系人列表：绿色圆点为在线，红色角标为未读，右上角按钮退出登录
- 聊天页：左下角 📷 发图片、📎 发任意文件，图片气泡点击看大图，文件气泡点击下载并打开
- 清空聊天记录：右上角 ⋯ 菜单 →「清空聊天记录」，**双方**的服务器历史（消息+文件）都会删除，不可恢复
- 多端互踢：同一账号在别处登录会把本机踢下线（与安卓/Windows 行为一致）

## 四、开发者说明（可选阅读）

- 工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述（`project.yml`），云端构建时自动生成 `.xcodeproj`，无需把 Xcode 工程文件入库
- 有 Mac 时：`brew install xcodegen && xcodegen generate` 后用 Xcode 打开即可，也可直接真机调试（免费 Apple ID 支持）
- 目录结构：
  ```
  SimpleChat/
  ├── App/     SimpleChatApp.swift（入口）、LoginView、ContactsView、ChatView、BubbleView、Pickers
  ├── Core/    CryptoBox（AES-256-GCM）、ChatConnection（WebSocket+重连）、ChatModel（会话状态）、
  │            HttpFileTransfer（上传下载）、Models
  └── Assets.xcassets  图标与主题色
  ```
- 协议与安卓/Windows 客户端完全一致，详见仓库根 `README.md` 的「通信协议」章节
- 服务器地址/端口在登录页填写并自动记住（首次为空，不预填）；通信密钥内置在 `SimpleChat/Core/ChatConnection.swift` 顶部的 `defaultSecret`

## 五、常见问题

| 问题 | 处理 |
|---|---|
| Actions 运行失败 | 看红叉日志；最常见原因是 `.github` 文件夹没传上去，或上传时目录层级多套了一层 |
| 下载的 IPA 解压后没有 .ipa | Artifacts 下载的是 zip，先解压一次 |
| Sideloadly 报 Apple ID 验证失败 | 开两步验证的账号需用"应用专用密码"；或换网络重试 |
| 装上后打开闪退/提示不受信任 | 设置 → 通用 → VPN与设备管理 → 信任开发者证书 |
| 连不上服务器 | 确认树莓派服务在运行、花生壳域名解析正常；App 使用 ws/http 明文连接，与安卓版环境要求相同 |
| 7 天后打不开 | 重新连电脑签一次名（第一节、第二节重复执行即可） |

> AI生成