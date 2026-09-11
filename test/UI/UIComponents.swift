import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct BrandMark: View {
    var compact = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 13 : 18, style: .continuous)
                .fill(Color.sicauButtonGreen.gradient)
            Image(systemName: "graduationcap.fill")
                .font(.system(size: compact ? 23 : 34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: compact ? 46 : 72, height: compact ? 46 : 72)
        .accessibilityLabel("Better Sicau")
    }
}

struct CaptchaImage: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 116, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .accessibilityLabel("登录验证码")
    }
}

struct QRCodeImage: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = Self.makeImage(from: url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .background(.white)
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "qrcode")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 236, height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityLabel("微信登录二维码")
    }

    private static func makeImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct AppSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal)
    }
}

struct StatPill: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct LoadingRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }
}

extension Color {
    static let sicauButtonGreen = Color(red: 0.10, green: 0.45, blue: 0.32)
    static let sicauGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.32, green: 0.78, blue: 0.60, alpha: 1)
            : UIColor(red: 0.10, green: 0.45, blue: 0.32, alpha: 1)
    })
    static let sicauOrange = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.65, blue: 0.35, alpha: 1)
            : UIColor(red: 0.86, green: 0.39, blue: 0.14, alpha: 1)
    })
    static let sicauBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.65, blue: 1, alpha: 1)
            : UIColor(red: 0.16, green: 0.36, blue: 0.72, alpha: 1)
    })

    /// Stable accent color for a weekday column, shared by list and grid views.
    static func scheduleTint(forDay day: Int?) -> Color {
        let colors: [Color] = [.sicauGreen, .sicauBlue, .sicauOrange, .purple, .pink, .teal, .indigo]
        return colors[max((day ?? 1) - 1, 0) % colors.count]
    }
}

struct SicauCard: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func sicauCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(SicauCard(cornerRadius: cornerRadius))
    }
}

struct RefreshToolbarButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "正在刷新" : "刷新数据")
    }
}

extension ScheduleItem {
    var displayDay: String {
        if !dayLabel.isEmpty { return dayLabel }
        guard let dayOfWeek else { return "未安排" }
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return labels.indices.contains(dayOfWeek - 1) ? labels[dayOfWeek - 1] : "第\(dayOfWeek)天"
    }

    var displaySections: String {
        if !sectionLabel.isEmpty { return sectionLabel }
        if let start = sectionStart {
            let end = sectionEnd ?? start
            return start == end ? "第\(start)节" : "第\(start)-\(end)节"
        }
        return "时间待定"
    }
}


extension GradeItem {
    var displayCourse: String {
        if !course.isEmpty { return course }
        if !name.isEmpty { return name }
        return "未命名课程"
    }

    var displayScore: String { score.isEmpty ? "-" : score }
}

/// Progress is reported by the service at each real network/parse boundary.
/// A phase bar shows completed steps, never an invented network percentage.
struct QueryStatusView: View {
    @ObservedObject var store: AppStore
    let scope: LoadingScope
    let retry: () -> Void

    private var state: AcademicLoadState { store.state(for: scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = state.progress {
                HStack(alignment: .firstTextBaseline) {
                    Text(progress.message).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("步骤 \(progress.step)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if progress.total > 1 {
                    ProgressView(value: Double(max(0, progress.step - 1)), total: Double(progress.total))
                        .tint(.sicauGreen)
                        .accessibilityLabel("已完成 \(progress.step - 1) 个步骤，共 \(progress.total) 步")
                    steps(progress)
                } else {
                    Text("正在连接学校服务，请稍候")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = state.error {
                Label(state.hasLoaded ? "更新失败，保留上次数据" : "获取失败", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重新获取", action: retry).buttonStyle(.bordered)
            } else if let date = state.updatedAt {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sicauGreen)
                    Text("更新于 \(updateTime(date))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            } else {
                HStack {
                    Text("等待获取数据").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("获取", action: retry).font(.subheadline)
                }
            }
            ForEach(state.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityElement(children: .contain)
    }

    private func updateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = ScheduleWeek.calendar.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func steps(_ progress: QueryProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(progress.steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 7) {
                    Image(systemName: index < progress.step - 1 ? "checkmark.circle.fill" : (index == progress.step - 1 ? "arrow.right.circle.fill" : "circle"))
                        .foregroundStyle(index < progress.step ? Color.sicauGreen : Color.secondary)
                    Text(title)
                        .foregroundStyle(index == progress.step - 1 ? Color.primary : Color.secondary)
                }
                .font(.caption)
            }
        }
    }
}

struct TermSelector: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Menu {
            ForEach(store.availableTerms, id: \.self) { term in
                Button {
                    Task { await store.changeTerm(to: term) }
                } label: {
                    if term == store.selectedTerm { Label(term, systemImage: "checkmark") }
                    else { Text(term) }
                }
            }
        } label: {
            Label(store.selectedTerm.isEmpty ? "选择学期" : store.selectedTerm, systemImage: "calendar")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
        }
        .accessibilityLabel("查看学期：\(store.selectedTerm)")
    }
}
