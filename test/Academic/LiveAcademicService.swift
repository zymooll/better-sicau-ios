import Foundation

actor LiveAcademicService: AcademicService {
    private enum Paths {
        static let gradeMenu = "/xuesheng/chengji/chengji/chengji.asp"
        static let grades = "/xuesheng/chengji/chengji/sear_ch_all.asp"
        static let effectiveGrades = "/xuesheng/chengji/chengji/sear_ch_xf.asp"
        static let rankInitialRequired = "/xuesheng/chengji/chengji/zytong_cx.asp"
        static let rankAll = "/xuesheng/chengji/chengji/zytongall.asp"
        static let exams = "/xuesheng/kao/kao/xuesheng.asp?title_id1=01"
        static let makeupExams = "/xuesheng/chengji/chengji/xxqk.asp"
        static let schedule = "/xuesheng/gongxuan/gongxuan/kbbanji.asp?title_id1=4"
        static let courseSelect = "/xuesheng/gongxuan/gongxuan/bxq.asp"
        static let onlineTeaching = "/xuesheng/gongxuan/gongxuan/zxian_rw_list.asp"
    }

    private struct CacheEntry<Value: Sendable>: Sendable {
        var value: Value
        var expiresAt: Date
        func isValid(at date: Date) -> Bool { expiresAt > date }
    }

    private struct Attempt<Value> {
        var value: Value?
        var error: Error?
        var succeeded: Bool { value != nil }
    }

    private struct TermState {
        var selectedTerm: String
        var verified: Bool
    }

    private let gateway: any JiaowuGateway
    private let cacheTTL: TimeInterval
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var operationActive = false
    private var operationGeneration: UUID?
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var gradeCache: CacheEntry<GradeSnapshot>?
    private var examCache: CacheEntry<[ExamItem]>?
    private var scheduleCache: [String: CacheEntry<[ScheduleItem]>] = [:]

    nonisolated private static let currentTermDefaultsKey = "academic.currentTerm"
    nonisolated private static let startDatesDefaultsKey = "academic.termStartDates"
    nonisolated private static let defaultStartDates = [
        "2025-2026-2": "2026-03-01",
        "2026-2027-1": "2026-09-07",
        "2026-2027-2": "2027-03-01",
    ]

    init(
        gateway: any JiaowuGateway,
        cacheTTL: TimeInterval = 5 * 60,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.cacheTTL = max(0, cacheTTL)
        self.defaults = userDefaults
        self.now = now
    }

    // The upstream stores the selected term in its session. Keep complete
    // academic operations serial, including across actor suspension points.
    private func acquireOperation() async {
        if !operationActive { operationActive = true; return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        operationGeneration = nil
        if operationWaiters.isEmpty { operationActive = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private func validate(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw AppError.requestCancelled }
    }

    func fetchGrades(forceRefresh: Bool) async throws -> GradeSnapshot {
        try await fetchGrades(forceRefresh: forceRefresh, progress: nil)
    }

    func fetchExams(forceRefresh: Bool) async throws -> [ExamItem] {
        try await fetchExams(forceRefresh: forceRefresh, progress: nil)
    }

    func fetchSchedule(term: String, forceRefresh: Bool) async throws -> [ScheduleItem] {
        try await fetchSchedule(term: term, forceRefresh: forceRefresh, progress: nil)
    }

    func fetchGrades(forceRefresh: Bool, progress: AcademicProgress?) async throws -> GradeSnapshot {
        let steps = ["验证教务登录状态", "读取成绩查询入口", "获取有效成绩", "获取必修课排名", "获取综合排名", "整理成绩与排名"]
        let expected = generation
        if operationActive { await progress?(.running(["等待其他查询完成"], at: 0)) }
        await acquireOperation()
        defer { releaseOperation() }
        try validate(expected)
        operationGeneration = expected
        await progress?(.running(steps, at: 0))
        try await gateway.ensureJiaowuSession()
        try validate(expected)
        if !forceRefresh, let gradeCache, gradeCache.isValid(at: now()) {
            Log.debug(.academic, LogMessage("成绩命中缓存（\(gradeCache.value.grades.count) 条）"))
            return gradeCache.value
        }

        let startedAt = Date()
        await progress?(.running(steps, at: 1))
        let grades = try await fetchEffectiveGrades(progress: progress, steps: steps)
        await progress?(.running(steps, at: 3))
        let initial = try await fetchRanking(path: Paths.rankInitialRequired, title: "初修必修加权排名")
        await progress?(.running(steps, at: 4))
        let all = try await fetchRanking(path: Paths.rankAll, title: "全部成绩加权排名")
        await progress?(.running(steps, at: 5))
        try validate(expected)
        let snapshot = GradeSnapshot(
            grades: grades,
            rankings: GradeRankings(initialRequired: initial, all: all),
            warnings: [(initial == nil ? "必修课排名暂不可用" : nil), (all == nil ? "综合排名暂不可用" : nil)].compactMap { $0 }
        )
        gradeCache = CacheEntry(value: snapshot, expiresAt: now().addingTimeInterval(cacheTTL))
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info(.academic, LogMessage("成绩抓取完成：\(grades.count) 条，耗时 \(elapsed) ms"))
        return snapshot
    }

    func fetchExams(forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ExamItem] {
        let steps = ["验证教务登录状态", "获取正考安排", "获取缓补考安排", "检查并合并考试数据"]
        let expected = generation
        if operationActive { await progress?(.running(["等待其他查询完成"], at: 0)) }
        await acquireOperation()
        defer { releaseOperation() }
        try validate(expected)
        operationGeneration = expected
        await progress?(.running(steps, at: 0))
        try await gateway.ensureJiaowuSession()
        try validate(expected)
        if !forceRefresh, let examCache, examCache.isValid(at: now()) {
            Log.debug(.academic, LogMessage("考试命中缓存（\(examCache.value.count) 条）"))
            return examCache.value
        }

        let startedAt = Date()
        await progress?(.running(steps, at: 1))
        let primary = await attempt { try await self.request(path: Paths.exams) }
        try rethrowTerminalError(primary.error)
        await progress?(.running(steps, at: 2))
        var makeup = await attempt { try await self.submitFirstForm(path: Paths.makeupExams) }
        try rethrowTerminalError(makeup.error)
        if !makeup.succeeded {
            makeup = await attempt { try await self.request(path: Paths.makeupExams) }
        }
        try rethrowTerminalError(makeup.error)
        guard primary.succeeded && makeup.succeeded else {
            try rethrowTerminalError(primary.error)
            try rethrowTerminalError(makeup.error)
            throw preferredFailure(label: "考试安排", errors: [primary.error, makeup.error])
        }

        await progress?(.running(steps, at: 3))
        try validate(expected)
        let primaryItems = primary.value.map(AcademicHTMLParser.parseExams) ?? []
        let makeupItems = (makeup.value.map(AcademicHTMLParser.parseExams) ?? []).map { item in
            var item = item
            if !item.isResit { item.type = item.type.isEmpty ? "缓补考" : "缓补考 · \(item.type)" }
            return item
        }
        guard AcademicHTMLParser.isConfirmedExamPage(primary.value ?? "", items: primaryItems),
              AcademicHTMLParser.isConfirmedExamPage(makeup.value ?? "", items: makeupItems) else {
            throw AppError.invalidResponse("考试页面格式异常，无法确认完整安排，请重试")
        }
        let items = uniqueExams(primaryItems + makeupItems)
        examCache = CacheEntry(value: items, expiresAt: now().addingTimeInterval(cacheTTL))
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info(.academic, LogMessage("考试抓取完成：正考 \(primaryItems.count) + 缓补 \(makeupItems.count) → 合并 \(items.count) 条，耗时 \(elapsed) ms"))
        return items
    }

    func fetchSchedule(term: String, forceRefresh: Bool, progress: AcademicProgress?) async throws -> [ScheduleItem] {
        let steps = ["验证教务登录状态", "切换并确认学期", "查找课表入口", "读取课程安排", "整理课程与周次"]
        let expected = generation
        if operationActive { await progress?(.running(["等待其他查询完成"], at: 0)) }
        await acquireOperation()
        defer { releaseOperation() }
        try validate(expected)
        operationGeneration = expected
        let requestedTerm = AcademicHTMLParser.normalizeTerm(term) ?? ""
        if !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && requestedTerm.isEmpty {
            throw AppError.validation("学期格式应为 2025-2026-1")
        }

        await progress?(.running(steps, at: 0))
        try await gateway.ensureJiaowuSession()
        try validate(expected)
        if !forceRefresh, !requestedTerm.isEmpty,
           let cached = scheduleCache[requestedTerm],
           cached.isValid(at: now()) {
            Log.debug(.academic, LogMessage("课表命中缓存（\(cached.value.count) 条，学期 \(requestedTerm)）"))
            return cached.value
        }

        let startedAt = Date()
        await progress?(.running(steps, at: 1))
        let termState = try await ensureTerm(requestedTerm)
        guard termState.verified else { throw AppError.invalidResponse("未能确认已切换到 \(requestedTerm) 学期，请重试") }
        await progress?(.running(steps, at: 2))
        let parentAttempt = await attempt { try await self.request(path: Paths.onlineTeaching) }
        try rethrowTerminalError(parentAttempt.error)
        let parentHTML = parentAttempt.value ?? ""
        let discovered = AcademicHTMLParser.findHrefByText(parentHTML, matching: "课表|kbbanji")
        let resolved = AcademicHTMLParser.resolveJiaowuHref(
            basePath: Paths.onlineTeaching,
            href: discovered ?? Paths.schedule
        )
        let candidates = uniqueStrings([resolved, Paths.schedule, Paths.courseSelect])

        var errors: [Error?] = [parentAttempt.error]
        var validPageSeen = false
        var confirmedEmpty = false
        for (index, path) in candidates.enumerated() {
            var detail = QueryProgress.running(steps, at: 3)
            if index > 0 { detail.message = "读取课程安排：尝试备用入口 \(index)" }
            await progress?(detail)
            try Task.checkCancellation()
            let candidate = await attempt { try await self.request(path: path) }
            try rethrowTerminalError(candidate.error)
            errors.append(candidate.error)
            guard let html = candidate.value else { continue }
            validPageSeen = true
            confirmedEmpty = confirmedEmpty || AcademicHTMLParser.isConfirmedEmptySchedulePage(html)
            let items = AcademicHTMLParser.parseSchedule(html)
            if !items.isEmpty {
                guard termState.verified else {
                    errors.append(AppError.invalidResponse("未能确认已切换到 \(requestedTerm) 学期"))
                    continue
                }
                await progress?(.running(steps, at: 4))
                try validate(expected)
                return cacheSchedule(items, requestedTerm: requestedTerm, state: termState, startedAt: startedAt)
            }
        }

        await progress?(.running(steps, at: 3))
        let posted = await attempt {
            try await self.submitFirstForm(
                path: Paths.onlineTeaching,
                overrides: requestedTerm.isEmpty ? [:] : ["xueqi": requestedTerm]
            )
        }
        try rethrowTerminalError(posted.error)
        errors.append(posted.error)
        if !validPageSeen && !posted.succeeded {
            throw preferredFailure(label: "课表", errors: errors)
        }
        let postedItems = posted.value.map(AcademicHTMLParser.parseSchedule) ?? []
        confirmedEmpty = confirmedEmpty || AcademicHTMLParser.isConfirmedEmptySchedulePage(posted.value ?? "")
        guard !postedItems.isEmpty || confirmedEmpty else {
            throw AppError.invalidResponse("课表页面格式异常，无法确认课程安排，请重试")
        }
        if !postedItems.isEmpty, !termState.verified {
            throw AppError.invalidResponse("未能确认已切换到 \(requestedTerm) 学期")
        }
        await progress?(.running(steps, at: 4))
        try validate(expected)
        return cacheSchedule(postedItems, requestedTerm: requestedTerm, state: termState, startedAt: startedAt)
    }

    func termSettings() async -> TermSettings {
        let savedTerm = defaults.string(forKey: Self.currentTermDefaultsKey)
            .flatMap(AcademicHTMLParser.normalizeTerm)
        let savedDates = (defaults.dictionary(forKey: Self.startDatesDefaultsKey) as? [String: String]) ?? [:]
        let startDates = Self.defaultStartDates.merging(savedDates) { _, saved in saved }
        return TermSettings(currentTerm: savedTerm ?? inferredCurrentTerm(at: now()), startDates: startDates)
    }

    func updateTermSettings(_ settings: TermSettings) throws {
        guard AcademicHTMLParser.normalizeTerm(settings.currentTerm) != nil else {
            throw AppError.validation("学期格式应为 2025-2026-1")
        }
        defaults.set(settings.currentTerm, forKey: Self.currentTermDefaultsKey)
        defaults.set(settings.startDates, forKey: Self.startDatesDefaultsKey)
    }

    func clearCache() {
        generation = UUID()
        Log.info(.academic, LogMessage("清空成绩/考试/课表内存缓存"))
        gradeCache = nil
        examCache = nil
        scheduleCache.removeAll()
    }

    private func fetchEffectiveGrades(progress: AcademicProgress?, steps: [String]) async throws -> [GradeItem] {
        var errors: [Error?] = []
        let menuAttempt = await attempt { try await self.request(path: Paths.gradeMenu) }
        try rethrowTerminalError(menuAttempt.error)
        errors.append(menuAttempt.error)
        let effectiveHref = menuAttempt.value.flatMap {
            AcademicHTMLParser.findHrefByText($0, matching: "有效学分成绩|sear_ch_xf")
        } ?? Paths.effectiveGrades
        let effectivePath = AcademicHTMLParser.resolveJiaowuHref(basePath: Paths.gradeMenu, href: effectiveHref)

        await progress?(.running(steps, at: 2))
        let effectiveAttempt = await attempt { try await self.request(path: effectivePath) }
        try rethrowTerminalError(effectiveAttempt.error)
        errors.append(effectiveAttempt.error)
        if let html = effectiveAttempt.value {
            let grades = AcademicHTMLParser.filterEffectiveGrades(AcademicHTMLParser.parseGrades(html))
            if AcademicHTMLParser.isConfirmedGradePage(html, items: grades) {
                return grades
            }
            errors.append(AppError.invalidResponse("有效学分成绩页面内容异常"))
        }

        let allAttempt = await attempt { try await self.request(path: Paths.grades) }
        try rethrowTerminalError(allAttempt.error)
        errors.append(allAttempt.error)
        if let html = allAttempt.value {
            let grades = AcademicHTMLParser.parseGrades(html)
            if AcademicHTMLParser.isConfirmedGradePage(html, items: grades) {
                return AcademicHTMLParser.filterEffectiveGrades(grades)
            }
            errors.append(AppError.invalidResponse("全部成绩页面内容异常"))
        }

        let postAttempt = await attempt {
            try await self.submitFirstForm(path: Paths.gradeMenu, preferredAction: Paths.grades)
        }
        try rethrowTerminalError(postAttempt.error)
        errors.append(postAttempt.error)
        if let html = postAttempt.value {
            let grades = AcademicHTMLParser.parseGrades(html)
            if AcademicHTMLParser.isConfirmedGradePage(html, items: grades) {
                return AcademicHTMLParser.filterEffectiveGrades(grades)
            }
            errors.append(AppError.invalidResponse("成绩查询结果页面内容异常"))
        }
        throw preferredFailure(label: "成绩", errors: errors)
    }

    private func fetchRanking(path: String, title: String) async throws -> GradeRanking? {
        do {
            let html = try await request(path: path)
            let ranking = AcademicHTMLParser.parseGradeRanking(html, fallbackTitle: title)
            guard AcademicHTMLParser.isConfirmedRankingPage(html, ranking: ranking) else {
                Log.notice(.academic, LogMessage("排名页面内容异常，降级为无排名（\(title)）"))
                return nil
            }
            return ranking
        } catch is CancellationError {
            throw AppError.requestCancelled
        } catch AppError.authenticationExpired {
            throw AppError.authenticationExpired
        } catch AppError.requestCancelled {
            throw AppError.requestCancelled
        } catch {
            Log.notice(.academic, LogMessage("排名抓取失败，降级为无排名（\(title)）：\(error.localizedDescription)"))
            return nil
        }
    }

    private func ensureTerm(_ requestedTerm: String) async throws -> TermState {
        let initialHTML = try await optionalRequest(path: Paths.courseSelect) ?? ""
        var terms = AcademicHTMLParser.parseTermOptions(initialHTML)
        var selected = AcademicHTMLParser.extractCurrentTerm(initialHTML)
        if selected.isEmpty { selected = terms.first(where: { $0.current })?.term ?? "" }
        if requestedTerm.isEmpty || selected == requestedTerm {
            return TermState(selectedTerm: selected, verified: true)
        }

        Log.info(.academic, LogMessage("切换学期：{from} → {to}", sensitive: ["from": selected.isEmpty ? "未知" : selected, "to": requestedTerm]))
        let termHref = terms.first(where: { $0.term == requestedTerm }).flatMap { $0.href.isEmpty ? nil : $0.href }
            ?? "xszhinan.asp?title_id1=9&xueqi=\(requestedTerm)"
        let switchPath = AcademicHTMLParser.resolveJiaowuHref(basePath: Paths.courseSelect, href: termHref)
        _ = try await optionalRequest(path: switchPath)
        guard let refreshed = try await optionalRequest(path: Paths.courseSelect),
              !refreshed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TermState(selectedTerm: "", verified: false)
        }
        terms = AcademicHTMLParser.parseTermOptions(refreshed)
        selected = AcademicHTMLParser.extractCurrentTerm(refreshed)
        if selected.isEmpty { selected = terms.first(where: { $0.current })?.term ?? "" }
        let verified = selected == requestedTerm
        return TermState(selectedTerm: selected, verified: verified)
    }

    private func cacheSchedule(
        _ items: [ScheduleItem],
        requestedTerm: String,
        state: TermState,
        startedAt: Date
    ) -> [ScheduleItem] {
        let itemTerm = state.selectedTerm.isEmpty ? requestedTerm : state.selectedTerm
        let normalized = items.map { item -> ScheduleItem in
            var item = item
            if item.term.isEmpty { item.term = itemTerm }
            return item
        }
        if !requestedTerm.isEmpty && state.verified && (state.selectedTerm.isEmpty || state.selectedTerm == requestedTerm) {
            scheduleCache[requestedTerm] = CacheEntry(value: normalized, expiresAt: now().addingTimeInterval(cacheTTL))
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info(.academic, LogMessage("课表抓取完成：\(normalized.count) 条（学期 \(itemTerm.isEmpty ? "未知" : itemTerm)），耗时 \(elapsed) ms"))
        return normalized
    }

    private func request(
        path: String,
        method: HTTPMethod = .get,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> String {
        let expected = operationGeneration ?? generation
        do {
            try validate(expected)
            let html = try await gateway.requestJiaowuText(path: path, method: method, body: body, headers: headers)
            try validate(expected)
            if AcademicHTMLParser.isAuthenticationPage(html) {
                throw AppError.authenticationExpired
            }
            return html
        } catch is CancellationError {
            throw AppError.requestCancelled
        }
    }

    private func optionalRequest(path: String) async throws -> String? {
        do {
            return try await request(path: path)
        } catch is CancellationError {
            throw AppError.requestCancelled
        } catch AppError.authenticationExpired {
            throw AppError.authenticationExpired
        } catch AppError.requestCancelled {
            throw AppError.requestCancelled
        } catch {
            return nil
        }
    }

    private func submitFirstForm(
        path: String,
        overrides: [String: String] = [:],
        preferredAction: String = ""
    ) async throws -> String {
        let page = try await request(path: path)
        let forms = AcademicHTMLParser.extractForms(page, baseURL: path).filter { !$0.fields.isEmpty }
        let preferred = preferredAction.isEmpty ? nil : forms.first {
            AcademicHTMLParser.samePath($0.action, preferredAction)
        }
        guard let form = preferred
                ?? forms.first(where: { $0.name.range(of: "jcrj", options: .caseInsensitive) != nil })
                ?? forms.first else {
            return page
        }
        let fields = ClassicASPFormEncoder.overriding(form.fields, with: overrides.filter { !$0.value.isEmpty })
        let action = AcademicHTMLParser.resolveJiaowuHref(basePath: path, href: form.action.isEmpty ? path : form.action)
        let body = ClassicASPFormEncoder.encode(fields)
        if form.method == .post {
            return try await request(
                path: action,
                method: .post,
                body: body,
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded; charset=gb2312",
                    "Content-Length": String(body.count)
                ]
            )
        }
        let query = String(data: body, encoding: .ascii) ?? ""
        guard !query.isEmpty else { return try await request(path: action) }
        return try await request(path: action + (action.contains("?") ? "&" : "?") + query)
    }

    private func attempt<Value>(_ operation: () async throws -> Value) async -> Attempt<Value> {
        do {
            return Attempt(value: try await operation(), error: nil)
        } catch {
            return Attempt(value: nil, error: error)
        }
    }

    private func rethrowTerminalError(_ error: Error?) throws {
        guard let error else { return }
        if error is CancellationError { throw AppError.requestCancelled }
        if let appError = error as? AppError {
            switch appError {
            case .authenticationExpired, .requestCancelled:
                throw appError
            default:
                break
            }
        }
    }

    private func preferredFailure(label: String, errors: [Error?]) -> AppError {
        for error in errors.compactMap({ $0 }) {
            if let appError = error as? AppError {
                switch appError {
                case .requestTimedOut, .upstreamUnavailable:
                    return appError
                default:
                    break
                }
            }
        }
        return AppError.upstreamUnavailable("\(label)数据读取失败")
    }

    private func uniqueExams(_ items: [ExamItem]) -> [ExamItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.id
            return seen.insert(key).inserted
        }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func inferredCurrentTerm(at date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        let year = components.year ?? 2026
        let month = components.month ?? 8
        if month >= 8 { return "\(year)-\(year + 1)-1" }
        if month == 1 { return "\(year - 1)-\(year)-1" }
        return "\(year - 1)-\(year)-2"
    }
}
