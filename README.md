# Better-Sicau for iOS

Better-Sicau 的原生 iPhone 版本。应用直接从 iPhone 访问四川农业大学 WebVPN 与教务系统，不依赖 Electron、本机 HTTP 服务或远程后端。当前包含账号、短信和微信登录，以及课表、考试、成绩与排名查询。查询时显示实际执行步骤、已完成步骤和最后更新时间；失败可单独重试，刷新失败保留上次成功数据。

## 环境要求

- 一台可运行完整 Xcode 的 Mac；工程由 Xcode 26.6 创建，建议使用 Xcode 26.6 或兼容的新版本。
- iOS 17.0 或更高版本的 iPhone。
- 已登录 Xcode 的 Apple ID，以及一个 Personal Team 或 Apple Developer Team。
- iPhone 能直接访问学校 WebVPN 和教务系统。

## 真机安装

1. 确认命令行工具指向完整 Xcode，而不是 Command Line Tools：

   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   ```

2. 打开 `test.xcodeproj`：

   ```sh
   open test.xcodeproj
   ```

3. 在 Xcode 中选择项目 `test`，进入应用 target `test` 的 **Signing & Capabilities**：
   - 勾选 **Automatically manage signing**。
   - 选择自己的 **Team**。
   - 将 `cn.better.sicau` 改为自己唯一的 Bundle Identifier，例如 `com.example.bettersicau`。
4. 首次使用数据线连接并信任 Mac。在 iPhone 的 **设置 > 隐私与安全性 > 开发者模式** 中开启开发者模式，按提示重启设备。
5. 在 Xcode 顶部选择已连接的 iPhone，按 `Cmd-R` 安装并运行。首次启动若出现开发者信任提示，按系统提示允许。
6. 无线安装需要先通过数据线配对，然后在 Xcode 的 **Window > Devices and Simulators** 中为该设备启用 **Connect via network**；之后 Mac 与 iPhone 位于同一网络时可直接运行。

使用免费 Apple ID 的 Personal Team 签名时，开发安装通常约 7 天后需要重新签名和安装。付费 Apple Developer 会员的开发签名周期通常更长，具体有效期以 Xcode 生成的证书和描述文件为准。本工程不包含 App Store、TestFlight、推送或后台模式配置。

## 构建与测试

命令行构建会使用工程中已配置的 Team 和 Bundle Identifier：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project test.xcodeproj -scheme test \
  -destination 'generic/platform=iOS' \
  -configuration Debug build
```

单元测试也可在 Xcode 中按 `Cmd-U` 运行。命令行运行前，先用 `xcrun simctl list devices available` 查找本机模拟器，并按实际设备名替换下例的 `iPhone 17 Pro`：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project test.xcodeproj -scheme test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' test
```

测试覆盖 Cookie 匹配与过期、GB18030 表单、MD5/AES 向量、HTTPS/重定向/超时/取消/响应上限，以及成绩、考试、课表和认证页面解析。真实账号与学校在线接口测试不会进入 CI。

## 界面与查询行为

- 首页优先加载课表，再加载考试和成绩；各页面展示服务层报告的步骤，而非模拟下载百分比。例如课表依次显示“验证教务登录状态 → 切换并确认学期 → 查找课表入口 → 读取课程安排 → 整理课程与周次”。
- 手动刷新绕过五分钟缓存；首次失败显示失败原因和“重新获取”，刷新失败保留旧数据。排名单独不可用时显示提示，不生成空白排名分区。
- 课表快速切换学期会取消旧请求并清空旧学期显示；服务器的学期状态切换与查询按完整操作串行执行。未能确认学期或页面格式异常会报错，不把异常页面当作空课表。
- 第一教学周从设置日期当天或之后的第一个周一开始，业务日期统一按上海时区计算；例如周日 `2026-03-01` 对应第一周周一 `2026-03-02`。设置页会说明此规则，请按实际教学安排调整日期。
- 课表支持重叠课程聚合与详情、待定课程列表、自适应列宽、固定星期/节次（iOS 18+ 使用系统滚动几何；iOS 17 使用坐标回退）、辅助大字体列表，以及深色主题。
- 考试默认展示本次取得的数据中的全部学期；可按学期和正考/缓补考筛选，日期推测的学期会明确标记。任一考试来源请求失败都会提示，避免把部分数据缓存成完整安排。
- 清除已保存账号会同时清空内存账号和密码；退出登录使在途请求失效，迟到的数据、Cookie 和错误不能重新写入新会话。

### 无账号的界面验收

演示入口已关闭，Debug 和 Release 均使用正常登录与学校数据流程，残留的 `--ui-review` 启动参数也不会启用演示。合成布局验证代码保留在 DebugFixtures 中，但当前不启用。

## 数据与安全

- 账号密码和会话 Cookie 保存在 iOS Keychain；只有开启“记住密码”时才保存密码。
- 成绩、考试和课表的五分钟查询缓存只保留在内存中，退出登录或登录失效时立即清空，避免跨账号数据串扰；学期设置使用 `UserDefaults`。
- 学期选择器提供 2025-2026-1 至 2035-2036-2 的完整学期列表；开学日期有预设值时自动填入，无预设值可在设置页手动填写（用于教学周次与考试学期推测）。考试保留上游学期；无学期且无法可靠推测的记录显示在“学期待确认”，不会按日期静默删除。
- 冷启动恢复会话时，仅在服务端明确拒绝（401/登录页）才清除本地会话；断网或上游抖动不会摧毁已保存的登录状态。
- 验证码识别通过 Apple Vision 在设备本地完成，识别失败时可手动输入。
- 网络请求只允许 HTTPS，并包含超时、取消、响应大小限制和手动重定向处理。
- 界面不展示密码、Cookie 或上游原始响应；退出登录会清理会话数据。
- HTML 解析使用 vendored 的 SwiftSoup（MIT 许可，来源与升级说明见 `test/ThirdParty/SwiftSoup/README.md`）。
- 日志：服务层、网络层与关键状态迁移（登录/登出/会话恢复/学期切换/缓存）写入 Apple 统一日志（OSLog，subsystem `cn.better.sicau`）和应用内环形缓冲（最近 2000 条）。密码、Cookie 值、验证码文本绝不入日志；学号、手机号默认显示为 `<redacted>`，仅「完整导出」包含明文。设置 > 诊断 > 日志可查看、筛选、导出（脱敏/完整）与清空；Mac 上可用 `log show --predicate 'subsystem == "cn.better.sicau"' --last 30m` 检索。

## 真机验收清单

- [ ] 账号密码登录：自动识别验证码失败时仍能手动输入并登录。
- [ ] 短信登录：发送验证码、提交验证码及错误提示正常。
- [ ] 微信登录：另一设备扫码可完成登录；同机打开链接、复制和系统分享可用。
- [ ] 成绩与两类排名和桌面版同一账号结果一致。
- [ ] 正考、缓考和补考条目完整，无重复或错误合并。
- [ ] 可切换学期查看课表，单双周、日期和节次显示正确。
- [ ] 设置页可选择 2025-2026-1 至 2035-2036-2 的学期；有预设的学期自动显示开学日期，无预设的可手动填写并保存。
- [ ] 未设置开学日期的学期，考试安排仍完整可见。
- [ ] 飞行模式下杀进程重开，能恢复会话进入首页；网络恢复后数据可用。
- [ ] 杀掉应用后重新打开可恢复有效会话；失效会话会返回登录页。
- [ ] 退出登录后无法恢复旧会话，已保存的敏感数据按预期清理。
- [ ] 退出登录后立即换另一账号登录，5 分钟内不出现上一账号的成绩、考试或课表数据。
- [ ] 断网、请求超时和学校页面变化时显示可理解的错误，且不泄露密码、Cookie 或原始响应。
- [ ] 设置 > 诊断 > 日志：完成登录/查成绩/登出后可看到对应条目；脱敏导出无学号明文，完整导出有；清空生效。

学校认证和教务页面可能随时调整。发布或长期使用前，应使用同一真实账号与桌面版逐项对照以上结果。
