import Foundation

/// Records-list sport menu.
///
/// The log has no stored filter. The menu is 全部 plus each `SportKind` that
/// actually appears in the loaded workouts, in `SportKind.allCases` order.
/// `apply` returns a new array for the rows on screen. It does not insert,
/// delete, or rewrite workout data, and it does not change distance, pace, or load.
enum RecordListFilter {
    static func sports(in workouts: [WorkoutRecord]) -> [SportKind] {
        let present = Set(workouts.map(\.sport))
        return SportKind.allCases.filter { present.contains($0) }
    }

    static func apply(_ sport: SportKind?, to workouts: [WorkoutRecord]) -> [WorkoutRecord] {
        guard let sport else { return workouts }
        return workouts.filter { $0.sport == sport }
    }
}

/// Approved list-card measurements, in points.
///
/// At the default text size the text block and the map block are both 112.
/// The sport chip needs a 30pt line, and the distance line is 32pt so the
/// larger kilometer figure is not clipped. The 213pt information track is the
/// width that keeps four 48.75pt columns with 6pt gaps on a 393pt phone.
/// Cards run edge to edge. Narrower cards shrink that track so the map still
/// fits; wider cards do not stretch the columns.
enum RecordListCardLayout {
    static let standardHeight = 112.0
    static let contentInsetVertical = 6.0
    static let titleLine = 30.0
    static let topToMiddle = 14.0
    static let upperLine = 32.0
    static let middleToBottom = 4.0
    static let lowerLine = 20.0
    static let mapSide = 104.0
    static let mapInsetVertical = 4.0
    static let mapTrailing = 16.0
    static let contentLeading = 16.0
    static let informationWidth = 213.0
    static let columnGap = 6.0
    static let columnCount = 4.0
    /// Visible gap between the month title and 全部. Same value as `SkyTheme.Spacing.related`.
    static let headerGap = 8.0
    static let firstCardGap = 10.0
    static let minimumMapGap = 8.0
    /// Thumbnail corner. Matches `SkyTheme.Radius.chip`.
    static let mapCorner = 12.0
    /// Share of the thumbnail side left clear on every edge, so the track
    /// sits in the center instead of touching the frame.
    static let mapTrackInsetFraction = 0.14

    static var standardTextBlock: Double {
        contentInsetVertical * 2 + titleLine + topToMiddle + upperLine + middleToBottom + lowerLine
    }

    static var standardMapBlock: Double {
        mapSide + mapInsetVertical * 2
    }

    static var columnWidth: Double {
        (informationWidth - columnGap * (columnCount - 1)) / columnCount
    }

    /// Width of the left data region inside the card.
    static func informationWidth(cardWidth: Double) -> Double {
        let room = cardWidth - contentLeading - mapTrailing - mapSide - minimumMapGap
        return min(informationWidth, max(0, room))
    }
}

/// How a route sits inside the square record thumbnail.
///
/// The longer ground axis fills the inner box. The shorter axis stays centered,
/// so every edge keeps `RecordListCardLayout.mapTrackInsetFraction` of the side
/// or more. The full-screen 1.6× map fit is not used here.
enum RecordThumbnailFit {
    struct Frame {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// Normalized frame inside a unit-square thumbnail.
    /// `width` and `height` are the track extent in the same ground units.
    static func normalizedFrame(width: Double, height: Double) -> Frame {
        let inset = RecordListCardLayout.mapTrackInsetFraction
        let inner = max(1 - inset * 2, 0.01)
        let spanX = max(width, 0)
        let spanY = max(height, 0)
        let limit = max(spanX, spanY, 1e-9)
        let drawWidth = inner * (spanX / limit)
        let drawHeight = inner * (spanY / limit)
        return Frame(
            x: (1 - drawWidth) / 2,
            y: (1 - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
    }
}

/// Lower row, left to right. Pace, heart rate, load, score.
/// Cadence and the motivation line are not list-card columns.
enum RecordListMetricColumn: String, CaseIterable {
    case pace
    case heartRate
    case load
    case score
}

/// Strings drawn on a record card. Missing numbers stay 「—」.
/// Distance keeps 公里. Pace keeps the minute and second marks.
/// Heart rate, load, and score are the number only.
enum RecordListCardText {
    /// Shanghai clock, matching the rest of the log. No seconds.
    /// Example: `2026-11-21 15:52 星期六`.
    static func started(_ date: Date) -> String {
        let day = startFormatter.string(from: date)
        let index = max(0, min(6, calendar.component(.weekday, from: date) - 1))
        return "\(day) 星期\(weekdays[index])"
    }

    /// Training duration, `HH:mm:ss`. Hours grow past 99 instead of clipping.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// One decimal and 公里, or 「—」 at or below 1 meter.
    static func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters > 1 else { return "—" }
        return String(format: "%.1f", meters / 1000) + "公里"
    }

    /// Whole kilocalories and 千卡, or 「—」 when none were recorded.
    static func energy(_ kilocalories: Double) -> String {
        guard kilocalories.isFinite, kilocalories >= 0.5 else { return "—" }
        return "\(Int(kilocalories.rounded()))千卡"
    }

    static func pace(_ secondsPerKm: Double) -> String {
        Format.pace(secondsPerKm)
    }

    static func heartRate(_ beatsPerMinute: Double) -> String {
        Format.integer(beatsPerMinute)
    }

    static func load(_ load: Int) -> String {
        load > 0 ? "\(load)" : "—"
    }

    /// `WorkoutRecord` has no per-record score. The list does not invent one.
    static let score = "—"

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
}

/// Copy for the load and score explanation.
///
/// Load is the existing Edwards TRIMP integer from `TrainingEstimate.sessionLoad`.
/// It is not an arbitrary unit. The list score is absent: analysis uses a separate
/// duration-weighted heart-rate intensity, and that number is not written onto the row.
enum RecordMetricHelp {
    static let title = "指标说明"
    static let loadTitle = "训练负荷"
    static let loadBody = "单次负荷是 Edwards TRIMP 的整数。各心率区间的训练分钟分别乘 1、2、3、4、5，相加后四舍五入。区间与详情页心率区间相同，参考最大心率 190：低于 114、114–132、133–151、152–170、171 及以上。有心率序列时按各区时间计算，暂停空档不计入。没有序列、但平均心率大于 0 时，整段训练时间记入该心率所在的区间。没有可用心率时显示 —。"
    static let scoreTitle = "训练评分"
    static let scoreBody = "单次记录没有评分字段，所以这里显示 —。分析页的训练评分是另一项汇总：只计入有心率的记录，强度为平均心率除以 180、上限 100，再按经过时间加权。列表不把这项汇总写进每一行。"
    static let missing = "— 表示没有数值，不是 0。"
}
