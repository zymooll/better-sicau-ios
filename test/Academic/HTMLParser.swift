import Foundation

#if canImport(SwiftSoup)
import SwiftSoup
#endif

// SwiftSoup is used both as a SwiftPM module and as vendored source in the
// app target. Keep parser construction compatible with both layouts.
#if canImport(SwiftSoup)
private func academicParseHTML(_ html: String) throws -> Document {
    try SwiftSoup.parse(html)
}

private func academicParseFragment(_ html: String) throws -> Document {
    try SwiftSoup.parseBodyFragment(html)
}
#else
private func academicParseHTML(_ html: String) throws -> Document {
    try parse(html)
}

private func academicParseFragment(_ html: String) throws -> Document {
    try parseBodyFragment(html)
}
#endif

/// SwiftSoup-backed parsers for the classic ASP pages exposed by the SICAU
/// teaching system. The upstream pages are inconsistent, so all parsers keep
/// the same header-driven fallback order as the desktop client.
nonisolated enum AcademicHTMLParser {
    struct FormField: Equatable, Sendable {
        var name: String
        var value: String
    }

    struct Form: Equatable, Sendable {
        var name: String
        var method: HTTPMethod
        var action: String
        var fields: [FormField]
    }

    struct TermOption: Equatable, Sendable {
        var term: String
        var href: String
        var current: Bool
    }

    struct Table {
        var rows: [[String]]
    }

    nonisolated static func stripTags(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        do {
            let document = try academicParseHTML(value)
            for element in try document.select("script, style") {
                try element.remove()
            }
            return normalizeWhitespace(try document.text())
        } catch {
            return value
                .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func htmlDecode(_ value: String) -> String {
        do {
            let document = try academicParseFragment(value)
            return try document.body()?.text() ?? value
        } catch {
            return value
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
        }
    }

    static func extractForms(_ html: String, baseURL: String = "") -> [Form] {
        do {
            let document = try academicParseHTML(html)
            let elements = try document.select("form")
            var forms: [Form] = []
            for element in elements {
                let name = (try? element.attr("name")) ?? ""
                let action = (try? element.attr("action")) ?? ""
                let methodValue = ((try? element.attr("method")) ?? "GET").uppercased()
                let method = methodValue == HTTPMethod.post.rawValue ? HTTPMethod.post : HTTPMethod.get
                let fields = try extractFormFields(from: element)
                forms.append(Form(name: name, method: method, action: action.isEmpty ? baseURL : action, fields: fields))
            }
            if !forms.isEmpty { return forms }
            return [Form(name: "", method: .get, action: baseURL, fields: try extractFormFields(from: document))]
        } catch {
            return [Form(name: "", method: .get, action: baseURL, fields: [])]
        }
    }

    static func extractFormFields(_ html: String) -> [FormField] {
        do {
            let document = try academicParseFragment(html)
            return try extractFormFields(from: document)
        } catch {
            return []
        }
    }

    private static func extractFormFields(from root: Element) throws -> [FormField] {
        var fields: [FormField] = []
        for element in try root.select("input, textarea, select") {
            let name = try element.attr("name")
            guard !name.isEmpty else { continue }
            let tag = element.tagName().lowercased()
            let type = ((try? element.attr("type")) ?? "").lowercased()
            if tag == "input" && ["submit", "button", "image", "reset", "file"].contains(type) { continue }
            let value: String
            switch tag {
            case "textarea":
                value = normalizedText(try element.html(), preserveLineBreaks: true)
            case "select":
                let options = try element.select("option")
                let selected = options.first(where: { $0.hasAttr("selected") }) ?? options.first
                if let selected {
                    value = (try? selected.attr("value")).flatMap { $0.isEmpty ? nil : $0 } ?? normalizedText((try? selected.html()) ?? "")
                } else {
                    value = ""
                }
            default:
                value = (try? element.attr("value")) ?? ""
            }
            fields.append(FormField(name: name, value: htmlDecode(value)))
        }
        return fields
    }

    static func tableObjects(_ html: String, fallbackColumns: [String] = []) -> [[String: String]] {
        tableObjects(html, fallbackColumns: fallbackColumns, headerPredicate: nil, score: nil)
    }

    private static func tableObjects(
        _ html: String,
        fallbackColumns: [String],
        headerPredicate: (([String]) -> Bool)?,
        score scoreFunction: (([String]) -> Int)?
    ) -> [[String: String]] {
        let tables = extractTables(html, keepEmpty: true)
        var candidates: [(table: Table, headerIndex: Int, score: Int, length: Int, order: Int)] = []
        var order = 0
        for table in tables {
            for (index, row) in table.rows.enumerated() {
                let score = scoreFunction?(row) ?? headerScore(row)
                let minimumHeaderCells = headerPredicate == nil ? 3 : 2
                if row.count >= minimumHeaderCells && score > 0,
                   headerPredicate.map({ $0(row) }) ?? true {
                    candidates.append((table, index, score, row.filter { !$0.isEmpty }.count, order))
                }
                order += 1
            }
        }
        // A specialized parser must never fall back to unrelated rows. That
        // fallback is useful for the legacy generic parser, but it is exactly
        // how a page from another menu can be read as a valid result.
        if headerPredicate != nil && candidates.isEmpty { return [] }
        let best = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.order < $1.order
        }.first
        let columns = best.map { candidate in
            candidate.table.rows[candidate.headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } ?? fallbackColumns
        let dataRows: [[String]]
        if let best {
            dataRows = Array(best.table.rows.dropFirst(best.headerIndex + 1))
        } else {
            dataRows = extractRows(html)
        }
        return dataRows.filter { row in
            row.contains(where: { !$0.isEmpty }) && row.count >= min(2, max(columns.count, 2))
        }.map { row in
            var output: [String: String] = [:]
            for index in 0..<max(columns.count, row.count) {
                let key = index < columns.count && !columns[index].isEmpty ? columns[index] : "列\(index + 1)"
                output[key] = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            return output
        }
    }

    private static func headerScore(_ row: [String]) -> Int {
        let exact = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let keys = ["序", "序号", "课程", "课程名称", "成绩", "绩点", "学期", "学分", "考试时间", "考试教室", "考试地点", "考核方式", "座位号", "教师", "上课时间", "教室", "周次"]
        var score = keys.reduce(0) { $0 + (exact.contains($1) ? 2 : 0) }
        if (exact.contains("课程") || exact.contains("课程名称"))
            && (exact.contains("成绩") || exact.contains("考试时间") || exact.contains("上课时间")) { score += 6 }
        if row.contains(where: isNavigationText) { score -= 10 }
        return score
    }

    private static func isGradeHeaderRow(_ row: [String]) -> Bool {
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let hasCourse = fields.contains("课程") || fields.contains("课程名称")
        guard hasCourse else { return false }

        // These fields are specific enough to distinguish a grade result from
        // a course list. "成绩" alone is allowed because the real pages often
        // omit optional columns, but an exam-shaped header without term/credit
        // or another grade field must not enter this parser.
        let gradeFields = ["成绩", "绩点", "成绩来源", "有效", "记分"]
        guard gradeFields.contains(where: fields.contains) else { return false }
        let examFields = ["考试时间", "补考时间", "考试教室", "考试地点", "考试周次", "考试星期", "考试节次", "座位号"]
        let hasExamShape = examFields.contains(where: fields.contains)
        let hasAdditionalGradeEvidence = ["绩点", "学期", "学分", "成绩来源", "有效", "记分"].contains(where: fields.contains)
        return !hasExamShape || hasAdditionalGradeEvidence
    }

    private static func gradeHeaderScore(_ row: [String]) -> Int {
        guard isGradeHeaderRow(row) else { return 0 }
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var score = headerScore(row)
        score += fields.intersection(["成绩", "绩点", "成绩来源", "有效", "记分"]).count * 3
        score += fields.intersection(["学期", "学分", "课程编号", "课程代码", "课程号", "课号"]).count
        if fields.intersection(["考试时间", "补考时间", "考试教室", "考试地点", "座位号"]).isEmpty == false { score -= 8 }
        return score
    }

    private static func isValidGradeItem(_ item: GradeItem) -> Bool {
        guard isRealCourseName(item.course), !isNavigationRow(item.raw) else { return false }
        // A grade row may have a blank score while the teacher has not posted
        // it yet, but it still needs another grade-table value or a sequence
        // number. This rejects menu rows such as "课程 / 点击查询".
        let hasGradeValue = [item.score, item.gradePoint, item.term, item.credit,
                             item.source, item.valid, item.courseType, item.note]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasGradeValue || Int(item.index) != nil else { return false }
        let examKeys = ["考试时间", "补考时间", "考试教室", "考试地点", "座位号"]
        return !examKeys.contains(where: { !(item.raw[$0] ?? "").isEmpty })
    }

    private static func hasGradeTable(_ html: String) -> Bool {
        extractTables(html, keepEmpty: true).contains { table in
            table.rows.contains(where: isGradeHeaderRow)
        }
    }

    private static func isScheduleHeaderRow(_ row: [String]) -> Bool {
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let hasCourse = fields.contains("课程") || fields.contains("课程名称")
        guard hasCourse else { return false }
        guard !isCourseSelectionHeader(row) else { return false }
        let scheduleFields = ["星期", "周几", "节次", "上课时间", "时间", "周次", "起止周"]
        guard scheduleFields.contains(where: fields.contains) else { return false }
        // "考试时间" is intentionally not treated as the generic "时间"
        // field; an exam result has no place in the timetable view.
        let examFields = ["考试时间", "补考时间", "考试教室", "考试地点", "座位号", "考试性质"]
        return !examFields.contains(where: fields.contains)
    }

    private static func isCourseSelectionHeader(_ row: [String]) -> Bool {
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let selectionFields = [
            "容量", "余量", "选课", "退课", "操作", "计划人数", "已选人数",
            "课程体系", "排课类别", "实验编号", "教学班号", "优选专业"
        ]
        return selectionFields.contains(where: fields.contains)
    }

    private static func scheduleHeaderScore(_ row: [String]) -> Int {
        guard isScheduleHeaderRow(row) else { return 0 }
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var score = headerScore(row)
        score += fields.intersection(["星期", "周几", "节次", "上课时间", "时间", "周次", "起止周"]).count * 3
        score += fields.intersection(["教师", "任课教师", "地点", "教室", "上课地点"]).count
        return score
    }

    static func extractRows(_ html: String) -> [[String]] {
        guard let document = try? academicParseHTML(html) else { return [] }
        var rows: [[String]] = []
        for row in (try? document.select("tr")) ?? Elements() {
            let cells = (try? row.select("th, td")) ?? Elements()
            let values = cells.map { normalizedText((try? $0.html()) ?? "", preserveLineBreaks: false) }.filter { !$0.isEmpty }
            if !values.isEmpty { rows.append(values) }
        }
        return rows
    }

    private static func extractTables(_ html: String, keepEmpty: Bool) -> [Table] {
        guard let document = try? academicParseHTML(html) else { return [] }
        var tables: [Table] = []
        for table in (try? document.select("table")) ?? Elements() {
            var rows: [[String]] = []
            for row in (try? table.select("tr")) ?? Elements() {
                let cells = (try? row.select("th, td")) ?? Elements()
                let values = cells.map { normalizedText((try? $0.html()) ?? "", preserveLineBreaks: true) }
                if keepEmpty ? values.contains(where: { !$0.isEmpty }) : values.contains(where: { !$0.isEmpty }) {
                    rows.append(keepEmpty ? values : values.filter { !$0.isEmpty })
                }
            }
            if !rows.isEmpty { tables.append(Table(rows: rows)) }
        }
        return tables
    }

    static func parseGrades(_ html: String) -> [GradeItem] {
        let fallback = ["序", "姓名", "班级", "年级", "课程", "教师", "课程性质", "学分", "记分", "学期", "成绩", "绩点", "成绩来源", "有效", "开课课程性质", "综测课程性质", "来源校区", "成绩说明"]
        return tableObjects(html,
                            fallbackColumns: fallback,
                            headerPredicate: isGradeHeaderRow,
                            score: gradeHeaderScore)
            .map { row in
                GradeItem(index: value(in: row, keys: ["序", "列1"]),
                          courseID: value(in: row, keys: ["课程编号", "课程代码", "课程号", "课号"]),
                          name: row["姓名"] ?? "",
                          className: row["班级"] ?? "",
                          year: row["年级"] ?? "",
                          course: value(in: row, keys: ["课程", "列5", "课程名称"]),
                          teacher: row["教师"] ?? "",
                          courseType: value(in: row, keys: ["课程性质", "开课课程性质"]),
                          credit: row["学分"] ?? "",
                          term: row["学期"] ?? "",
                          score: row["成绩"] ?? "",
                          gradePoint: row["绩点"] ?? "",
                          source: row["成绩来源"] ?? "",
                          valid: row["有效"] ?? "",
                          campus: row["来源校区"] ?? "",
                          note: row["成绩说明"] ?? "",
                          raw: row)
            }
            .filter(isValidGradeItem)
    }

    static func parseGradeRanking(_ html: String, fallbackTitle: String = "") -> GradeRanking {
        let title = pageTitle(html).isEmpty ? fallbackTitle : pageTitle(html)
        var metrics: [RankingMetric] = []
        for table in extractTables(html, keepEmpty: true) {
            collectHeaderMetrics(table.rows, into: &metrics)
            collectPairMetrics(table.rows, into: &metrics)
        }
        if metrics.isEmpty { collectTextMetrics(stripTags(html), into: &metrics) }
        let deduped = uniqueMetrics(metrics).filter { usefulRankingMetric(label: $0.label, value: $0.value) }
        let display = deduped.filter { $0.label.range(of: "排名|名次|位次|加权|平均|绩点|成绩|人数|学分", options: .regularExpression) != nil }
        let summary = display.prefix(5).map { "\($0.label)：\($0.value)" }.joined(separator: "；")
        return GradeRanking(title: title,
                            summary: summary,
                            metrics: deduped,
                            rawText: stripTags(html).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(1000).description)
    }

    static func isConfirmedExamPage(_ html: String, items: [ExamItem]) -> Bool {
        guard !isAuthenticationPage(html) else { return false }
        if !items.isEmpty { return true }
        if extractTables(html, keepEmpty: true).contains(where: { $0.rows.contains(where: isExamHeaderRow) }) { return true }
        return stripTags(html).range(of: "(?:暂无|没有|未安排|未查询到).{0,12}(?:考试|补考)|(?:考试|补考).{0,12}(?:暂无|未安排|无记录)", options: .regularExpression) != nil
    }

    static func isConfirmedEmptySchedulePage(_ html: String) -> Bool {
        guard !isAuthenticationPage(html) else { return false }
        return stripTags(html).range(of: "(?:暂无|没有|未安排|未查询到).{0,12}(?:课程|课表)|(?:课程|课表).{0,12}(?:暂无|未安排|无记录)", options: .regularExpression) != nil
    }

    static func parseExams(_ html: String) -> [ExamItem] {
        let rows = examTableObjects(html)
        return rows.map { row in
            ExamItem(course: value(in: row, keys: ["课程", "课程名称", "考试课程", "科目", "列2"]),
                     time: value(in: row, keys: ["考试时间", "补考时间", "时间", "日期", "列3"]),
                     location: value(in: row, keys: ["考试地点", "考试教室", "地点", "教室", "列4"]),
                     seat: value(in: row, keys: ["座位号", "座位", "列5"]),
                     teacher: value(in: row, keys: ["教师", "任课教师"]),
                     type: value(in: row, keys: ["考试性质", "考核方式", "类型", "考试类型"]),
                     term: row["学期"] ?? "",
                     note: value(in: row, keys: ["备注", "说明", "发布"]),
                     raw: row)
        }.filter(isValidExamItem)
    }

    static func parseSchedule(_ html: String) -> [ScheduleItem] {
        let detail = parseScheduleDetailTable(html)
        if !detail.isEmpty { return detail }
        for table in extractTables(html, keepEmpty: true) {
            // Course-selection grids can contain numeric capacity/remaining
            // columns that look like weekday headers to the generic grid
            // parser. Reject the whole table before interpreting its cells.
            guard !table.rows.contains(where: isCourseSelectionHeader) else { continue }
            let grid = parseScheduleGrid(table.rows)
            if !grid.isEmpty { return grid }
        }
        return tableObjects(html,
                            fallbackColumns: ["序", "课程", "星期", "节次", "教师", "地点", "周次", "备注"],
                            headerPredicate: isScheduleHeaderRow,
                            score: scheduleHeaderScore)
            .map(normalizeScheduleObject)
            .filter(isValidScheduleItem)
    }

    static func parseTermOptions(_ html: String) -> [TermOption] {
        guard let document = try? academicParseHTML(html) else { return [] }
        var output: [TermOption] = []
        for option in (try? document.select("select[name=xueqi] option")) ?? Elements() {
            let text = (try? option.text()) ?? ""
            let value = (try? option.attr("value")) ?? ""
            guard let term = normalizeTerm(value) ?? normalizeTerm(text) else { continue }
            output.append(TermOption(term: term, href: "", current: option.hasAttr("selected")))
        }
        for link in (try? document.select("a")) ?? Elements() {
            let href = (try? link.attr("href")) ?? ""
            let body = (try? link.html()) ?? ""
            let text = normalizedText(body, preserveLineBreaks: false)
            let term = normalizeTerm(text) ?? normalizeTerm(queryValue("xueqi", in: href))
            guard let term else { continue }
            let current = ((try? link.attr("style")) ?? "").range(of: "color\\s*:\\s*red", options: .regularExpression) != nil
                || text.contains("当前")
            output.append(TermOption(term: term, href: href, current: current))
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0.term).inserted }
    }

    static func extractCurrentTerm(_ html: String) -> String {
        if let selected = parseTermOptions(html).first(where: { $0.current }) { return selected.term }
        let text = stripTags(html)
        let patterns = [#"当前学期状态[:：]\s*(\d{4}-\d{4}-[12])"#, #"(\d{4}-\d{4}-[12])\s*开课目录"#, #"当前学期[:：]?\s*(\d{4}-\d{4}-[12])"#]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: text), match.count > 1 { return match[1] }
        }
        return ""
    }

    static func normalizeTerm(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^\d{4}-\d{4}-[12]$"#, options: .regularExpression) != nil else { return nil }
        return normalized
    }

    static func findHrefByText(_ html: String, matching pattern: String) -> String? {
        guard let document = try? academicParseHTML(html) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for link in (try? document.select("a")) ?? Elements() {
            let href = (try? link.attr("href")) ?? ""
            let text = (try? link.text()) ?? ""
            let range = NSRange(location: 0, length: (text + " " + href).utf16.count)
            if regex.firstMatch(in: text + " " + href, range: range) != nil { return href }
        }
        return nil
    }

    static func resolveJiaowuHref(basePath: String, href: String) -> String {
        let raw = href.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return normalizeJiaowuPath(basePath) }
        if raw.range(of: #"^(https?:)?//"#, options: .regularExpression) != nil || raw.hasPrefix("/") {
            return normalizeJiaowuPath(raw)
        }
        if raw.range(of: #"^(javascript|mailto):"#, options: [.regularExpression, .caseInsensitive]) != nil { return normalizeJiaowuPath(basePath) }
        let base = normalizeJiaowuPath(basePath).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let baseDirectory = base.hasSuffix("/") ? base : String(base.prefix(upTo: base.lastIndex(of: "/") ?? base.endIndex)) + "/"
        var parts: [String] = []
        for part in (baseDirectory + raw).split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(String(part)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func normalizeJiaowuPath(_ value: String) -> String {
        let raw = value.replacingOccurrences(of: "&amp;", with: "&")
        if raw.lowercased().hasPrefix("http") {
            if let url = URL(string: raw) {
                if url.host?.lowercased() == "webvpn.sicau.edu.cn", url.path.hasPrefix("/https/") {
                    let pieces = url.path.split(separator: "/")
                    if pieces.count >= 3 { return "/" + pieces.dropFirst(2).joined(separator: "/") + (url.query.map { "?\($0)" } ?? "") }
                }
                return url.path + (url.query.map { "?\($0)" } ?? "")
            }
        }
        if raw.hasPrefix("/https/") {
            let pieces = raw.split(separator: "/")
            if pieces.count >= 3 { return "/" + pieces.dropFirst(2).joined(separator: "/") }
        }
        return raw.hasPrefix("/") ? raw : "/" + raw
    }

    static func samePath(_ first: String, _ second: String) -> Bool {
        normalizeJiaowuPath(first).split(separator: "?").first.map(String.init)?.lowercased()
            == normalizeJiaowuPath(second).split(separator: "?").first.map(String.init)?.lowercased()
    }

    static func isAuthenticationPage(_ html: String) -> Bool {
        let source = html
        if source.range(of: "账号验证失败|登录超时|重新登录|密码错误", options: .regularExpression) != nil { return true }
        if source.range(of: "index_out_mi", options: .caseInsensitive) != nil { return true }
        if source.range(of: #"window\.location\.href\s*=\s*['"][^'"]*index\.asp"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if source.range(of: #"vpn_eval\(\(function\(\)\{\s*alert\("#, options: [.regularExpression, .caseInsensitive]) != nil && source.range(of: "index.asp", options: .caseInsensitive) != nil { return true }
        if source.count < 1200 && source.contains("__vpn_hostname_data") && source.contains("alert(") { return true }
        if containsLoginEndpoint(in: source) { return true }
        let text = stripTags(source)
        if text.range(of: "统一认证|用户登录|请输入[^。；]{0,20}(?:密码|验证码)|login\\s*form", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    private static func containsLoginEndpoint(in html: String) -> Bool {
        guard let document = try? academicParseHTML(html) else { return false }
        for element in (try? document.select("form[action], a[href]")) ?? Elements() {
            let attribute = element.tagName().lowercased() == "form" ? "action" : "href"
            guard let rawValue = try? element.attr(attribute), isLoginEndpoint(rawValue) else { continue }
            return true
        }
        return false
    }

    private static func isLoginEndpoint(_ value: String) -> Bool {
        let decoded = htmlDecode(value)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return false }

        let path = URLComponents(string: decoded)?.percentEncodedPath
            ?? decoded.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init)
            ?? ""
        guard let endpoint = path.removingPercentEncoding?
            .split(separator: "/", omittingEmptySubsequences: true)
            .last?
            .lowercased() else { return false }
        return endpoint == "login" || endpoint == "login.asp"
    }

    static func isConfirmedGradePage(_ html: String, items: [GradeItem]) -> Bool {
        if isAuthenticationPage(html) { return false }
        // Parsed rows are not sufficient evidence by themselves: a schedule
        // or exam page can contain a course-looking row. Require the source
        // page to expose a grade-specific header before accepting the result.
        if hasGradeTable(html) { return true }
        let text = stripTags(html)
        let hasGradeContext = text.range(of: "成绩|绩点|学分成绩|成绩查询", options: .regularExpression) != nil
        let isEmptyGradeResult = text.range(of: "暂无(?:相关)?成绩|无成绩记录|没有查询到[^。；]{0,20}成绩|\\(?\\s*0\\s*条\\s*\\)?|记录数\\s*[:：]?\\s*0", options: .regularExpression) != nil
        return hasGradeContext && isEmptyGradeResult
    }

    static func isConfirmedRankingPage(_ html: String, ranking: GradeRanking) -> Bool {
        if isAuthenticationPage(html) { return false }
        if ranking.metrics.contains(where: { $0.label.range(of: "排名|名次|位次|加权", options: .regularExpression) != nil }) { return true }
        let text = stripTags(html)
        return text.range(of: "排名|名次|位次|加权", options: .regularExpression) != nil
            && text.range(of: "暂无|无排名|没有查询到|\\(?\\s*0\\s*条\\s*\\)?", options: .regularExpression) != nil
    }

    static func filterEffectiveGrades(_ items: [GradeItem]) -> [GradeItem] {
        items.filter { item in
            let text = [item.valid, item.note, item.raw["有效"] ?? "", item.raw["成绩说明"] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            return text.range(of: #"(^|[^\u4e00-\u9fa5])否($|[^\u4e00-\u9fa5])|无效"#, options: .regularExpression) == nil
        }
    }

    private static func collectHeaderMetrics(_ rows: [[String]], into output: inout [RankingMetric]) {
        for (index, row) in rows.enumerated() {
            guard row.filter(isRankingLabel).count >= 2 else { continue }
            guard let data = rows[(index + 1)..<rows.count].first(where: { $0.contains(where: { !$0.isEmpty }) && $0.count >= 2 }) else { continue }
            for (column, label) in row.enumerated() where isRankingLabel(label) {
                guard column < data.count else { continue }
                let value = cleanMetricValue(data[column])
                if !value.isEmpty && value != label { output.append(RankingMetric(label: cleanMetricLabel(label), value: value)) }
            }
        }
    }

    private static func collectPairMetrics(_ rows: [[String]], into output: inout [RankingMetric]) {
        for row in rows {
            guard row.count >= 2 else { continue }
            for index in 0..<(row.count - 1) {
                let label = cleanMetricLabel(row[index])
                let value = cleanMetricValue(row[index + 1])
                if isRankingLabel(label) && !value.isEmpty && value != label && !isRankingLabel(value) { output.append(RankingMetric(label: label, value: value)) }
            }
        }
    }

    private static func collectTextMetrics(_ text: String, into output: inout [RankingMetric]) {
        let patterns = [
            #"(初修必修加权排名|全部成绩加权排名|有效必修加权排名|专业排名|班级排名|年级排名|排名|名次|位次|加权平均成绩|加权成绩|平均绩点|平均成绩|年级总人数|专业总人数|总人数|年级人数|专业人数|人数)\s*[:：]\s*([^\n；;，, ]+)"#,
            #"(加权平均成绩|加权成绩|平均绩点|平均成绩)\s*为\s*([0-9.]+)"#,
            #"(排名|名次|位次)\s*为\s*([0-9/／\-.]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 3,
                      let labelRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text) else { return }
                output.append(RankingMetric(label: cleanMetricLabel(String(text[labelRange])), value: cleanMetricValue(String(text[valueRange]))))
            }
        }
    }

    private static func uniqueMetrics(_ items: [RankingMetric]) -> [RankingMetric] {
        var seen = Set<String>()
        return items.compactMap { item in
            let label = cleanMetricLabel(item.label)
            let value = cleanMetricValue(item.value)
            guard !label.isEmpty, !value.isEmpty, seen.insert("\(label)\t\(value)").inserted else { return nil }
            return RankingMetric(label: label, value: value)
        }
    }

    private static func isRankingLabel(_ value: String) -> Bool {
        let text = cleanMetricLabel(value)
        guard !text.isEmpty, text.count <= 24, !isNavigationText(text) else { return false }
        if text.range(of: "点击|下载|查询|成绩单|课程|说明|备注|地址|链接|ref", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return text.range(of: "排名|名次|位次|加权|平均|绩点|成绩|人数|学分|学号|姓名|班级|年级|专业", options: .regularExpression) != nil
    }

    private static func usefulRankingMetric(label: String, value: String) -> Bool {
        guard !value.isEmpty, !isNavigationText(value), value.range(of: #"^\(?\d+条\)?$"#, options: .regularExpression) == nil else { return false }
        if value.range(of: "下载|点击|查询|javascript:", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if value.range(of: "在读情况|在读状态|在校状态|休学|退学|毕业|结业", options: .regularExpression) != nil { return false }
        if label.range(of: "排名|名次|位次", options: .regularExpression) != nil && !isNumericRankingValue(value) { return false }
        return isRankingLabel(label) || "\(label)\(value)".range(of: "排名|名次|位次|加权|平均|绩点", options: .regularExpression) != nil
    }

    private static func isNumericRankingValue(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return normalized.range(of: #"^[0-9０-９]+(?:/[0-9０-９]+)?$"#, options: .regularExpression) != nil
    }

    private static func examTableObjects(_ html: String) -> [[String: String]] {
        var output: [[String: String]] = []
        for table in extractTables(html, keepEmpty: true) {
            guard let headerIndex = table.rows.firstIndex(where: isExamHeaderRow) else { continue }
            let columns = table.rows[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for row in table.rows.dropFirst(headerIndex + 1) where row.contains(where: { !$0.isEmpty }) {
                var object: [String: String] = [:]
                for index in 0..<columns.count { object[columns[index].isEmpty ? "列\(index + 1)" : columns[index]] = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
                output.append(object)
            }
        }
        if output.isEmpty && stripTags(html).range(of: "考试时间|考试教室|考试周次|补考时间|座位号", options: .regularExpression) != nil {
            return tableObjects(html, fallbackColumns: ["序", "课程", "考试时间", "考试地点", "座位号", "考试性质", "备注"])
        }
        return output
    }

    private static func isExamHeaderRow(_ row: [String]) -> Bool {
        let fields = Set(row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let hasCourse = fields.contains("课程") || fields.contains("课程名称") || fields.contains("考试课程") || fields.contains("科目")
        let hasExam = ["考试时间", "补考时间", "考试教室", "考试地点", "考试周次", "考试星期", "考试节次", "座位号", "考核方式"].contains(where: fields.contains)
        return hasCourse && hasExam
    }

    private static func isValidExamItem(_ item: ExamItem) -> Bool {
        guard isRealCourseName(item.course), !isNavigationRow(item.raw) else { return false }
        let haystack = [item.course, item.time, item.location, item.seat, item.type, item.term, item.note].joined(separator: " ")
        if haystack.range(of: "提示|特别提示|原则上|禁止考生|签到|公选课选考目录|拟排考课程列表|考试安排查询", options: .regularExpression) != nil { return false }
        return !item.time.isEmpty || !item.location.isEmpty || !item.seat.isEmpty || !item.type.isEmpty || haystack.range(of: #"\d"#, options: .regularExpression) != nil
    }

    private static func parseScheduleDetailTable(_ html: String) -> [ScheduleItem] {
        var output: [ScheduleItem] = []
        for table in extractTables(html, keepEmpty: true) {
            guard let headerIndex = table.rows.firstIndex(where: {
                $0.contains("课程名称") && $0.contains("上课时间") && !isCourseSelectionHeader($0)
            }) else { continue }
            let columns = table.rows[headerIndex]
            for values in table.rows.dropFirst(headerIndex + 1) {
                var row: [String: String] = [:]
                for index in 0..<columns.count { row[columns[index]] = index < values.count ? values[index].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
                let course = row["课程名称"] ?? ""
                guard isRealCourseName(course) else { continue }
                let times = splitLines(row["上课时间"] ?? "")
                let rooms = splitLines(row["教室"] ?? "")
                let teacher = row["教师"] ?? ""
                let weeks = row["周次"] ?? ""
                if times.isEmpty || (row["上课时间"] ?? "").range(of: "自行安排|待定", options: .regularExpression) != nil {
                    output.append(ScheduleItem(course: course, dayLabel: row["上课时间"] ?? "", sectionLabel: row["上课时间"] ?? "", teacher: teacher, location: row["教室"] ?? "", weeks: weeks, note: row["考核方法"] ?? "", raw: row))
                    continue
                }
                for (index, time) in times.enumerated() {
                    let match = firstMatch(#"(\d)\s*-\s*(\d+)\s*,\s*\d\s*-\s*(\d+)(.*)"#, in: time) ?? firstMatch(#"(\d)\s*-\s*(\d+)(.*)"#, in: time)
                    let day = match.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? dayNumber(time)
                    let start = match.flatMap { $0.count > 2 ? Int($0[2]) : nil } ?? firstNumber(time)
                    let end = match?.count == 5 ? Int(match![3]) : start
                    let suffix = match?.count == 5 ? match![4] : (match?.count == 4 ? match![3] : "")
                    output.append(ScheduleItem(course: course,
                                               dayOfWeek: day,
                                               dayLabel: day.map(dayLabel) ?? "",
                                               sectionStart: start,
                                               sectionEnd: end,
                                               sectionLabel: start != nil && end != nil ? "\(start!)-\(end!)节" : time,
                                               teacher: teacher,
                                               location: rooms.indices.contains(index) ? rooms[index] : (rooms.first ?? ""),
                                               weeks: (weeks + suffix).trimmingCharacters(in: .whitespacesAndNewlines),
                                               note: row["考核方法"] ?? "",
                                               raw: row))
                }
            }
        }
        return output
    }

    private static func parseScheduleGrid(_ rows: [[String]]) -> [ScheduleItem] {
        guard let header = rows.first(where: { $0.filter({ dayHeaderNumber($0) != nil }).count >= 3 }) else { return [] }
        var output: [ScheduleItem] = []
        for row in rows where row != header && row.count >= 3 {
            let section = row[0]
            for index in 1..<row.count {
                let cell = row[index]
                let day = index < header.count ? dayNumber(header[index]) : nil
                guard let day, !cell.isEmpty, cell.range(of: "上午|下午|晚上|节次", options: .regularExpression) == nil, !isNavigationText(cell) else { continue }
                let parts = cell.components(separatedBy: .newlines)
                    .flatMap { $0.components(separatedBy: "  ") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                output.append(ScheduleItem(course: parts.first ?? cell,
                                           dayOfWeek: day,
                                           dayLabel: dayLabel(day),
                                           sectionStart: firstNumber(section),
                                           sectionEnd: lastNumber(section),
                                           sectionLabel: section,
                                           teacher: parts.count > 1 ? parts[1] : "",
                                           location: parts.count > 2 ? parts[2] : "",
                                           weeks: parts.first(where: { $0.contains("周") }) ?? "",
                                           note: parts.dropFirst(3).joined(separator: " "),
                                           raw: ["section": section, "cell": cell]))
            }
        }
        return output
    }

    private static func normalizeScheduleObject(_ row: [String: String]) -> ScheduleItem {
        let dayText = value(in: row, keys: ["星期", "周几", "上课时间", "列3"])
        let sectionText = value(in: row, keys: ["节次", "时间", "上课时间", "列4"])
        let day = dayNumber(dayText)
        return ScheduleItem(course: value(in: row, keys: ["课程", "课程名称", "列2"]),
                            dayOfWeek: day,
                            dayLabel: day.map(dayLabel) ?? dayText,
                            sectionStart: firstNumber(sectionText),
                            sectionEnd: lastNumber(sectionText),
                            sectionLabel: sectionText,
                            teacher: value(in: row, keys: ["教师", "任课教师", "列5"]),
                            location: value(in: row, keys: ["地点", "教室", "上课地点", "列6"]),
                            weeks: value(in: row, keys: ["周次", "起止周", "列7"]),
                            note: value(in: row, keys: ["备注", "说明"]),
                            raw: row)
    }

    private static func isValidScheduleItem(_ item: ScheduleItem) -> Bool {
        isRealCourseName(item.course) && !isNavigationRow(item.raw)
            && (!item.dayLabel.isEmpty || item.sectionStart != nil || !item.sectionLabel.isEmpty || !item.location.isEmpty || !item.teacher.isEmpty || !item.weeks.isEmpty)
    }

    private static func isRealCourseName(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if isNavigationText(text) { return false }
        return text.range(of: #"^(课程|课程名称|科目|undefined|null)$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func isNavigationRow(_ row: [String: String]) -> Bool {
        let values = row.values.filter { !$0.isEmpty }
        guard !values.isEmpty else { return false }
        return values.filter(isNavigationText).count >= max(1, Int(ceil(Double(values.count) * 0.6)))
    }

    private static func isNavigationText(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^【[^】]+】$"#, options: .regularExpression) != nil
            || text.range(of: "选/退课指南|开课目录|在线教学|退课申请|特殊实验课表|选课情况|公选课选考目录|拟排考课程列表|考试安排查询|点击|查询|查看|登录|返回|首页|帮助|提交|下一页|上一页", options: .regularExpression) != nil
    }

    private static func cleanMetricLabel(_ value: String) -> String {
        value.replacingOccurrences(of: #"[：:]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMetricValue(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(in row: [String: String], keys: [String]) -> String {
        keys.compactMap { row[$0] }.first(where: { !$0.isEmpty }) ?? ""
    }

    private static func pageTitle(_ html: String) -> String {
        if let document = try? academicParseHTML(html) {
            let titleCell = try? document.select("td.g_title, th.g_title").first()
            if let titleCell { return normalizedText((try? titleCell.html()) ?? "") }
            return normalizedText((try? document.title()) ?? "")
        }
        return ""
    }

    private static func normalizedText(_ html: String, preserveLineBreaks: Bool = false) -> String {
        let lineBreakMarker = "SICAU_LINE_BREAK_7F3A"
        var source = html
        if preserveLineBreaks {
            source = source.replacingOccurrences(of: #"<br\s*/?>"#, with: lineBreakMarker, options: [.regularExpression, .caseInsensitive])
        }
        do {
            let document = try academicParseFragment(source)
            let text = (try document.body()?.text() ?? source).replacingOccurrences(of: lineBreakMarker, with: "\n")
            if preserveLineBreaks {
                return text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return source.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func splitLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private static func firstNumber(_ value: String) -> Int? { firstMatch(#"(\d+)"#, in: value).flatMap { $0.count > 1 ? Int($0[1]) : nil } }
    private static func lastNumber(_ value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return firstNumber(value) }
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: value.utf16.count))
        guard let range = matches.last.flatMap({ Range($0.range, in: value) }) else { return firstNumber(value) }
        return Int(value[range])
    }

    private static func dayNumber(_ value: String) -> Int? {
        let text = value
        let patterns: [(String, Int)] = [("星期一|周一|礼拜一", 1), ("星期二|周二|礼拜二", 2), ("星期三|周三|礼拜三", 3), ("星期四|周四|礼拜四", 4), ("星期五|周五|礼拜五", 5), ("星期六|周六|礼拜六", 6), ("星期日|星期天|周日|周天|礼拜日", 7)]
        for (pattern, number) in patterns where text.range(of: pattern, options: .regularExpression) != nil { return number }
        return firstMatch(#"[1-7]"#, in: text).flatMap { Int($0.first ?? "") }
    }

    private static func dayHeaderNumber(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, Int)] = [("星期一|周一|礼拜一|^一$", 1), ("星期二|周二|礼拜二|^二$", 2), ("星期三|周三|礼拜三|^三$", 3), ("星期四|周四|礼拜四|^四$", 4), ("星期五|周五|礼拜五|^五$", 5), ("星期六|周六|礼拜六|^六$", 6), ("星期日|星期天|周日|周天|礼拜日|^日$|^天$", 7)]
        for (pattern, number) in patterns where text.range(of: pattern, options: .regularExpression) != nil { return number }
        if text.range(of: #"^[1-7]$"#, options: .regularExpression) != nil { return Int(text) }
        return nil
    }

    private static func dayLabel(_ day: Int) -> String { "星期\(["一", "二", "三", "四", "五", "六", "日"][max(1, min(7, day)) - 1])" }

    private static func queryValue(_ key: String, in href: String) -> String {
        guard let components = URLComponents(string: href) else { return "" }
        return components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value ?? ""
    }

    private static func firstMatch(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
