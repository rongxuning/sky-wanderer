import Foundation

enum Format {
    static func kilometers(_ meters: Double) -> String {
        String(format: "%.2f", meters / 1000)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0, secondsPerKm < 3_600 else { return "—" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d'%02d\"", total / 60, total % 60)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分钟"
        }
        return "\(seconds) 秒"
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func dayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    /// Groups newest-first dates into 「yyyy年M月」 spans.
    /// Each span starts at the newest date of that month, so a section header sits above
    /// that record. The title is not delayed until the oldest date in the month.
    static func recordMonthSpans(dates: [Date]) -> [RecordMonthSpan] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月"
        var spans: [RecordMonthSpan] = []
        var index = 0
        while index < dates.count {
            let title = formatter.string(from: dates[index])
            var end = index + 1
            while end < dates.count, formatter.string(from: dates[end]) == title {
                end += 1
            }
            spans.append(RecordMonthSpan(title: title, lowerBound: index, upperBound: end))
            index = end
        }
        return spans
    }

    /// Home record cards. Today and yesterday use Shanghai local days, matching `time`.
    static func relativeDayTime(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let clock = time(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(clock)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(clock)"
        }
        return dayTime(date)
    }

    static func number(_ value: Double, digits: Int = 0) -> String {
        guard value > 0 else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    static func integer(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return String(Int(value.rounded()))
    }

    /// Detail sheet. Home cards keep `dayTime` and `relativeDayTime`, which omit the year.
    static func dateSpan(from start: Date, to end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月d日"
        return "\(formatter.string(from: start)) \(time(start))–\(time(end))"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f°C", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func humidity(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// Chinese grades for an AQI number. Bands match the familiar 优/良 scale.
    static func airQualityGrade(_ index: Int) -> String {
        switch index {
        case ..<0:
            return ""
        case 0...50:
            return "优"
        case 51...100:
            return "良"
        case 101...150:
            return "轻度"
        case 151...200:
            return "中度"
        case 201...300:
            return "重度"
        default:
            return "严重"
        }
    }

    static func airQuality(index: Int?, grade: String?) -> String {
        guard let index, index >= 0 else { return "—" }
        let stored = grade?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = stored.isEmpty ? airQualityGrade(index) : stored
        if label.isEmpty { return "\(index)" }
        return "\(index) \(label)"
    }

    /// Place name plus the start coordinate. No coordinate → 「—」.
    static func startPoint(name: String?, latitude: Double?, longitude: Double?) -> String {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return "—" }
        let numbers = String(
            format: "%.6f, %.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude
        )
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return numbers }
        return "\(trimmed) · \(numbers)"
    }
}

/// One year-month in a newest-first record list. Indexes point into that same date array.
struct RecordMonthSpan: Equatable, Identifiable {
    var title: String
    var lowerBound: Int
    var upperBound: Int

    var id: String { "\(lowerBound)-\(title)" }
    var range: Range<Int> { lowerBound..<upperBound }
}

extension KilometerSplit {
    /// Meters shown in the splits table. A full kilometer is 1000 when an older row
    /// did not store distance. A short last kilometer uses the stored remainder.
    var listedDistanceMeters: Double {
        if distanceMeters > 0 { return distanceMeters }
        return partial ? 0 : 1_000
    }

    /// Moving seconds shown in the time column. A full kilometer saved before
    /// duration existed used `paceSecPerKm` as that time.
    var listedDuration: TimeInterval {
        if durationSeconds > 0 { return durationSeconds }
        if !partial, paceSecPerKm > 0 { return paceSecPerKm }
        if listedDistanceMeters > 0, paceSecPerKm > 0 {
            return paceSecPerKm * (listedDistanceMeters / 1_000)
        }
        return 0
    }

    /// Clock time for this row. The leftover kilometer uses its own duration, not a dash.
    var listedTimeText: String {
        Format.clock(listedDuration)
    }

    /// `1.00` for a full kilometer. The leftover row is its real distance, never 「未满」.
    var listedDistanceText: String {
        if partial {
            return Format.kilometers(listedDistanceMeters)
        }
        return "1.00"
    }
}
