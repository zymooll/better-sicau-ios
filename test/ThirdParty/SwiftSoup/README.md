# SwiftSoup（vendored）

- 上游仓库: <https://github.com/scinfu/SwiftSoup>
- 许可证: MIT（见同目录 LICENSE，jsoup © 2009-2025 Jonathan Hedley；
  Swift port © 2016-2025 Nabil Chatbi）
- 引入方式: 源码直接 vendored 进 app target（`test/ThirdParty/SwiftSoup`），
  测试与可导入模块的场景则使用 SwiftPM 的 SwiftSoup 模块；`AcademicHTMLParser`
  通过 `#if canImport(SwiftSoup)` 兼容两种布局。
- vendoring 日期: 2026-08（随 initial commit 引入，具体上游 commit 未能追溯；
  如需核对版本请以本目录源码与上游 diff 为准）。

## 升级注意事项

- 整目录替换后必须重跑 `BetterSicauTests` 中的 `HTMLParserTests` 与
  `AuthenticationDetectionTests`，上游解析行为变化会直接影响成绩/考试/课表解析。
- 本目录内不要做局部修改；若确有需要，必须在此 README 记录 diff 原因。
