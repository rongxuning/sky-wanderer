import Foundation

/// Records-list sport menu.
///
/// The log has no stored filter. The chip bar is 全部 plus each `SportKind` that
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
/// The map is a fixed square on the left whose side equals the fixed metrics
/// stack height (width = height = `standardTextBlock`). Distance is leading and
/// duration is trailing in equal halves. Secondary metrics are the value row
/// only: first leading, middle centered, last trailing so the last cell shares
/// duration’s right edge. The map and the metrics together sit 10pt inside every
/// card edge.
enum RecordListCardLayout {
    /// Card height: vertical insets plus the fixed text / map side.
    static var standardHeight: Double {
        contentInsetVertical * 2 + standardTextBlock
    }
    static let contentInsetVertical = 10.0
    static let titleLine = 22.0
    /// Gap between the title row and the distance / duration row.
    static let titleToMiddle = 12.0
    /// Fits the 32pt distance / energy figure.
    static let upperLine = 36.0
    /// Gap between the distance row and the secondary metrics.
    static let middleToBottom = 6.0
    static let lowerValueLine = 14.0
    static let mapLeading = 10.0
    static let mapToContent = 14.0
    static let contentTrailing = 10.0
    static let informationWidth = 220.0
    /// Horizontal gap between the sticky month title and the sport chips.
    /// Same value as `SkyTheme.Spacing.related`.
    static let headerGap = 8.0
    /// Space under the header row before the list starts.
    static let filterBarBottom = 10.0
    /// Horizontal gap between sport filter capsules.
    static let filterChipGap = 8.0
    static let filterChipPaddingH = 12.0
    static let filterChipPaddingV = 7.0
    static let firstCardGap = 10.0
    /// Thumbnail corner. Slightly tighter than `SkyTheme.Radius.chip`.
    static let mapCorner = 4.0
    /// Fallback / pending stroke width inside the square before the basemap lands.
    static let mapTrackLineWidth = 5.5
    /// Matches `TrackPaint.recordListInnerPoints` on the baked basemap plate.
    static let mapTrackBasemapLineWidth = 7.0
    /// Clearance past the centerline so the thicker of the canvas end dot
    /// (`0.55 × mapTrackLineWidth`) and the basemap stroke stay inside the frame.
    static let mapTrackEdgePad = max(mapTrackLineWidth * 0.55, mapTrackBasemapLineWidth / 2)

    static var lowerBlock: Double {
        lowerValueLine
    }

    static var standardTextBlock: Double {
        titleLine
            + titleToMiddle
            + upperLine
            + middleToBottom
            + lowerBlock
    }

    /// Fixed square side. Same as `standardTextBlock` so the plate’s bottom
    /// meets the secondary row. Not resized from live layout.
    static var mapSide: Double { standardTextBlock }

    /// `mapTrackEdgePad` as a fraction of `mapSide`. Long axis meets this inset;
    /// short axis stays centered with more margin.
    static var mapTrackInsetFraction: Double { mapTrackEdgePad / mapSide }

    static var standardMapBlock: Double {
        mapSide
    }

    /// Width of the right data region inside the card.
    static func informationWidth(cardWidth: Double) -> Double {
        let room = cardWidth - mapLeading - mapSide - mapToContent - contentTrailing
        return min(informationWidth, max(0, room))
    }
}

/// List-card chrome. Duration stays on ink with the start-time text.
/// The sport-type chip uses a softer dark gray so the badge does not dominate.
/// Neither follows `SportKind.listAccentHex`.
enum RecordListChrome {
    static let labelHex: UInt32 = 0x1C1C1E
    /// Sport chip fill. Same value as `SkyTheme.Color.starryChip`.
    static let chipFillHex: UInt32 = 0x3A3A3C
}

/// What the list card draws on the left plate.
enum RecordListThumbnailKind: Equatable {
    /// GPS polyline, two or more points.
    case track
    /// One start coordinate — neighborhood map with a round pin.
    case startPoint
    /// No usable coordinate. Most sports use the glass plate; 力量 / 综合 keep
    /// the map chrome via `listUsesStartLocationMap` instead of an icon image.
    case swatch

    static func resolve(routeCount: Int) -> RecordListThumbnailKind {
        if routeCount >= 2 { return .track }
        if routeCount == 1 { return .startPoint }
        return .swatch
    }
}

/// How a route sits inside the square record thumbnail.
///
/// The longer ground axis meets the half-stroke inset on both sides. The shorter
/// axis stays centered with more margin. Horizontally and vertically the track
/// is centered; at least one axis is flush to the inset. The full-screen 1.6×
/// map fit is not used here.
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

    /// Grow an aspect-filled map rect so a point pad survives without MK edge
    /// padding. MapKit's edge padding can leave extra empty space and bias the
    /// track toward the bottom after tiles load.
    static func visibleMapScale(side: Double, edgePad: Double) -> Double {
        let usable = max(side - edgePad * 2, 1)
        return side / usable
    }
}

/// Lower row, left to right. Heart rate, pace, load, score.
/// Cadence and the motivation line are not list-card columns.
enum RecordListMetricColumn: String, CaseIterable {
    case heartRate
    case pace
    case load
    case score

    var unit: String {
        switch self {
        case .heartRate: return "次/分"
        case .pace: return "分/公里"
        case .load: return "TL"
        case .score: return "评分"
        }
    }
}

/// One secondary metric that has a value to draw on the list card.
struct RecordListSecondaryMetric: Equatable, Identifiable {
    var column: RecordListMetricColumn
    var value: String

    var id: String { column.rawValue }
    var unit: String { column.unit }

    /// Heart rate, pace, load, score — skip missing cells, keep order.
    static func visible(in workout: WorkoutRecord) -> [RecordListSecondaryMetric] {
        var items: [RecordListSecondaryMetric] = []
        let heart = RecordListCardText.heartRate(workout.resolvedAverageHeartRate)
        if heart != "—" {
            items.append(RecordListSecondaryMetric(column: .heartRate, value: heart))
        }
        if workout.sport.listShowsRouteMetrics {
            let pace = RecordListCardText.pace(workout.averagePaceSecPerKm)
            if pace != "—" {
                items.append(RecordListSecondaryMetric(column: .pace, value: pace))
            }
        }
        let load = RecordListCardText.load(workout.sessionLoad)
        if load != "—" {
            items.append(RecordListSecondaryMetric(column: .load, value: load))
        }
        if RecordListCardText.score != "—" {
            items.append(RecordListSecondaryMetric(column: .score, value: RecordListCardText.score))
        }
        return items
    }
}

/// Horizontal alignment inside an equal-width secondary column.
/// First leading, middle centered, last trailing — so three cells read evenly
/// and the last cell shares the duration’s right edge.
enum RecordListSecondaryColumnAlign: Equatable {
    case leading
    case center
    case trailing

    static func resolve(index: Int, count: Int) -> RecordListSecondaryColumnAlign {
        guard count > 1 else { return .leading }
        if index == 0 { return .leading }
        if index == count - 1 { return .trailing }
        return .center
    }
}

/// Strings drawn on a record card. Missing numbers stay 「—」 for formatters;
/// the list hides those cells instead of drawing the dash.
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
    static let loadBody = "单次负荷是 Edwards TRIMP 的整数。各心率区间的训练分钟分别乘 1、2、3、4、5，相加后四舍五入。区间与详情页心率区间相同，参考最大心率 190：低于 114、114–132、133–151、152–170、171 及以上。有心率序列时按各区时间计算，暂停空档不计入。没有序列、但平均心率大于 0 时，整段训练时间记入该心率所在的区间。没有可用心率时，列表不展示负荷。"
    static let scoreTitle = "训练评分"
    static let scoreBody = "单次记录没有评分字段，所以列表不展示评分。分析页的训练评分是另一项汇总：只计入有心率的记录，强度为平均心率除以 180、上限 100，再按经过时间加权。列表不把这项汇总写进每一行。"
    static let missing = "没有数值的指标不出现在列表卡片上，不是 0。"
}
