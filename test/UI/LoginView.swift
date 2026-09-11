import SwiftUI
import UIKit

struct LoginView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    brand
                    loginPanel
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            BrandMark()
            VStack(spacing: 4) {
                Text("Better Sicau")
                    .font(.largeTitle.bold())
                Text("在 iPhone 上访问教务信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var loginPanel: some View {
        VStack(spacing: 22) {
            Picker("登录方式", selection: $store.loginMode) {
                ForEach(LoginMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isLoading(.login) || store.isLoading(.logout))

            Group {
                switch store.loginMode {
                case .password:
                    passwordForm
                case .wechat:
                    wechatForm
                case .sms:
                    smsForm
                }
            }
            .animation(.snappy, value: store.loginMode)
        }
        .padding(20)
        .sicauCard()
    }

    private var passwordForm: some View {
        VStack(spacing: 16) {
            LabeledContent("账号") {
                TextField("学号或账号", text: $store.username)
                    .textContentType(.username)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.next)
            }

            Divider()

            LabeledContent("密码") {
                SecureField("登录密码", text: $store.password)
                    .textContentType(.password)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.next)
            }

            Divider()

            captchaFields

            Toggle("记住密码", isOn: $store.rememberPassword)
                .tint(.sicauButtonGreen)

            Button {
                Task { await store.loginWithPassword() }
            } label: {
                HStack(spacing: 8) {
                    if store.isLoading(.login) { ProgressView().tint(.white) }
                    Text(store.isLoading(.login) ? "正在登录" : "登录")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.sicauButtonGreen)
            .disabled(store.isLoading(.login) || store.isLoading(.captcha) || store.isLoading(.logout))
        }
    }

    private var smsForm: some View {
        VStack(spacing: 16) {
            LabeledContent("手机号") {
                TextField("手机号", text: $store.phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .multilineTextAlignment(.trailing)
            }

            Divider()

            captchaFields

            Divider()

            HStack(spacing: 12) {
                TextField("短信验证码", text: $store.smsCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)

                Button {
                    Task { await store.sendSMSCode() }
                } label: {
                    if store.isLoading(.sms) {
                        ProgressView()
                            .frame(minWidth: 74)
                    } else {
                        Text(store.smsCooldown > 0 ? "\(store.smsCooldown)s" : "获取验证码")
                            .frame(minWidth: 74)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.smsCooldown > 0 || store.isLoading(.sms) || store.isLoading(.captcha))
            }

            Button {
                Task { await store.loginWithSMS() }
            } label: {
                HStack(spacing: 8) {
                    if store.isLoading(.login) { ProgressView().tint(.white) }
                    Text(store.isLoading(.login) ? "正在登录" : "短信登录")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.sicauButtonGreen)
            .disabled(store.isLoading(.login) || store.isLoading(.logout))
        }
    }

    private var captchaFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("图形验证码", text: $store.captchaText)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 12) {
                CaptchaImage(data: store.captchaChallenge?.imageData)
                Spacer()
                Button {
                    Task { await store.refreshCaptcha() }
                } label: {
                    if store.isLoading(.captcha) {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 30, height: 44)
                .disabled(store.isLoading(.captcha) || store.isLoading(.recognition) || store.isLoading(.login))
                .accessibilityLabel("刷新图形验证码")
                }
            }

            if store.isLoading(.recognition) {
                Label("正在识别验证码", systemImage: "text.viewfinder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if let recognition = store.captchaRecognition {
                if recognition.confidence >= 0.55, !recognition.text.isEmpty, recognition.text == store.captchaText {
                    Label("验证码已识别", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.sicauGreen)
                        .font(.caption)
                } else if recognition.confidence < 0.55 || recognition.text.isEmpty {
                    Label("识别不确定，请手动输入", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.sicauOrange)
                        .font(.caption)
                }
            }

            Button {
                Task { await store.recognizeCaptcha() }
            } label: {
                Label(
                    store.isLoading(.recognition)
                        ? "正在识别"
                        : (store.captchaRecognition == nil ? "识别验证码" : "重新识别"),
                    systemImage: "text.viewfinder"
                )
                .font(.subheadline.weight(.medium))
            }
            .disabled(store.captchaChallenge == nil || store.isLoading(.captcha) || store.isLoading(.recognition))
        }
    }

    private var wechatForm: some View {
        VStack(spacing: 18) {
            if store.isLoading(.wechat) {
                LoadingRow(message: "正在获取登录二维码")
            } else if let state = store.wechatState {
                QRCodeImage(url: state.url)
                wechatStatus(state)

                if let url = state.url {
                    HStack(spacing: 12) {
                        Link(destination: url) {
                            Label("打开", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)

                        ShareLink(item: url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            UIPasteboard.general.url = url
                            store.notice = AppNotice(message: "登录链接已复制")
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                }

                if state.status == .expired {
                    Button("重新获取二维码") {
                        Task { await store.restartWechatLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.sicauButtonGreen)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 66, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button("获取微信登录二维码") {
                        Task { await store.startWechatLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.sicauButtonGreen)
                }
                .padding(.vertical, 28)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func wechatStatus(_ state: WechatLoginState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: wechatStatusSymbol(state.status))
                .foregroundStyle(wechatStatusColor(state.status))
            Text(state.message.isEmpty ? wechatStatusText(state.status) : state.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func wechatStatusText(_ status: WechatLoginStatus) -> String {
        switch status {
        case .pending: return "等待扫码"
        case .scanned: return "已扫码，请在微信中确认"
        case .bindRequired: return "需要先完成账号绑定"
        case .success: return "登录成功"
        case .expired: return "二维码已过期"
        }
    }

    private func wechatStatusSymbol(_ status: WechatLoginStatus) -> String {
        switch status {
        case .pending: return "clock"
        case .scanned, .bindRequired: return "iphone.gen2.radiowaves.left.and.right"
        case .success: return "checkmark.circle.fill"
        case .expired: return "exclamationmark.circle.fill"
        }
    }

    private func wechatStatusColor(_ status: WechatLoginStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .scanned, .bindRequired: return .sicauOrange
        case .success: return .sicauGreen
        case .expired: return .red
        }
    }
}
