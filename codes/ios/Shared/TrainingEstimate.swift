import Foundation

struct TrainingEstimateSummary: Equatable {
    var reserve: Int
    var recentLoad: Int
    var restHint: String
}

enum TrainingEstimate {
    /// 训练估计，不是医疗建议。
    ///
    /// 单次负荷是 Edwards TRIMP，跑步和徒步同一套，不再乘运动系数：
    ///   round(Z1 分钟×1 + Z2 分钟×2 + Z3 分钟×3 + Z4 分钟×4 + Z5 分钟×5)
    /// 分钟可以是小数，最后再把和四舍五入成整数。
    /// 区间和详情页「心率区间」一致，参考最大心率固定 190（`ZoneDwell.heartBands`）：
    /// Z1 <114、Z2 114–132、Z3 133–151、Z4 152–170、Z5 ≥171。
    ///
    /// 有可用心率序列时，各区秒数用 `ZoneDwell.shares`（暂停空档不计入，和心率区间卡同一套）。
    /// 序列给不出区时间、但平均心率是正数时，全部训练分钟记进该平均心率所在的区。
    /// 两者都没有时，这一次负荷记为 0。
    /// 例：41 分 23 秒、平均心率 137、没有序列，全部落在 Z3，round((41+23/60)×3) = 124。
    ///
    /// 近 7 日负荷 = 开始时间落在过去 7×24 小时里的单次负荷之和。
    /// Edwards 负荷大约是旧公式的 3–4 倍，休息门槛和储备除数按 ×3 跟上：
    /// 体能储备 = max(0, 100 − 近 7 日负荷 / 15)。100 表示这 7 天没有负荷。
    /// 休息时间建议：
    /// - 近 7 日负荷 ≥ 1050 → 建议休息 48 小时
    /// - 近 7 日负荷 ≥ 600 → 建议休息 24 小时
    /// - 否则 → 可以正常训练
    /// 训练评分仍是心率 / 180，不在这里改（见 `RecordStats`）。
    static func sessionLoad(
        trainingDuration: TimeInterval,
        heartRate: [SeriesPoint],
        averageHeartRate: Double
    ) -> Int {
        let shares = ZoneDwell.shares(
            points: ZoneDwell.positiveSamples(heartRate),
            bands: ZoneDwell.heartBands
        )
        if shares.reduce(0.0, { $0 + $1.seconds }) > 0 {
            let raw = shares.enumerated().reduce(0.0) { partial, item in
                partial + item.element.seconds / 60 * Double(item.offset + 1)
            }
            return Int(raw.rounded())
        }
        guard trainingDuration > 0, averageHeartRate > 0 else { return 0 }
        let weight = Double(ZoneDwell.heartZone(averageHeartRate))
        return Int((trainingDuration / 60 * weight).rounded())
    }

    static func summarize(workouts: [WorkoutRecord], now: Date = Date()) -> TrainingEstimateSummary {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = workouts.reduce(0) { partial, workout in
            guard workout.start >= cutoff else { return partial }
            return partial + workout.sessionLoad
        }
        let reserve = max(0, 100 - recent / 15)
        let hint: String
        if recent >= 1050 {
            hint = "建议休息 48 小时"
        } else if recent >= 600 {
            hint = "建议休息 24 小时"
        } else {
            hint = "可以正常训练"
        }
        return TrainingEstimateSummary(reserve: reserve, recentLoad: recent, restHint: hint)
    }
}

enum RecordStats {
    /// 平均配速 = 有距离记录的训练时间 / 总公里，不是各次配速的算术平均。
    /// 平均心率优先用训练时段的序列（暂停空档不计入）。没有可用序列时用存储的平均值。
    /// 平均步频 = 各次总步数 / 训练分钟（`resolvedAverageCadence`）。
    /// 平均步幅 = 各次距离 / 总步数，因此和该次配速一致；再按经过时间加权。
    /// 没有步数时平均步幅为 0，界面显示「—」。
    /// 平均负荷 = 窗口内各次负荷的算术平均，包含负荷为 0 的记录。
    /// 总负荷 = 各次负荷之和。
    /// 训练评分 = 有心率记录的时长加权强度（心率 / 180，上限 100）。还没有单独的评分字段。
    static func make(workouts: [WorkoutRecord], window: StatsWindow, now: Date = Date()) -> TrainingStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let matched = workouts.filter { workout in
            switch window {
            case .week:
                return calendar.isDate(workout.start, equalTo: now, toGranularity: .weekOfYear)
            case .month:
                return calendar.isDate(workout.start, equalTo: now, toGranularity: .month)
            case .year:
                return calendar.isDate(workout.start, equalTo: now, toGranularity: .year)
            case .all:
                return true
            }
        }
        guard !matched.isEmpty else { return .empty }
        let heartPool = matched.filter { $0.resolvedAverageHeartRate > 0 }
        let cadencePool = matched.filter { $0.resolvedAverageCadence > 0 }
        let heartDuration = heartPool.reduce(0) { $0 + $1.duration }
        let cadenceDuration = cadencePool.reduce(0) { $0 + $1.duration }
        let heart = heartDuration > 0 ? heartPool.reduce(0) { $0 + $1.resolvedAverageHeartRate * $1.duration } / heartDuration : 0
        let cadence = cadenceDuration > 0 ? cadencePool.reduce(0) { $0 + $1.resolvedAverageCadence * $1.duration } / cadenceDuration : 0
        let moving = matched.filter { $0.distanceMeters > 1 && $0.trainingDuration > 0 }
        let movingDistance = moving.reduce(0) { $0 + $1.distanceMeters }
        let movingDuration = moving.reduce(0) { $0 + $1.trainingDuration }
        let pace = movingDistance > 1 ? movingDuration / (movingDistance / 1000) : 0
        let stridePool = matched.filter { $0.averageStrideMeters > 0 && $0.duration > 0 }
        let strideDuration = stridePool.reduce(0) { $0 + $1.duration }
        let stride = strideDuration > 0
            ? stridePool.reduce(0) { $0 + $1.averageStrideMeters * $1.duration } / strideDuration
            : 0
        let totalLoad = matched.reduce(0) { $0 + $1.sessionLoad }
        let load = Double(totalLoad) / Double(matched.count)
        let scoreDuration = heartPool.reduce(0) { $0 + $1.duration }
        let score = scoreDuration > 0
            ? heartPool.reduce(0) { partial, workout in
                let intensity = min(100, (workout.resolvedAverageHeartRate / 180) * 100)
                return partial + intensity * workout.duration
            } / scoreDuration
            : 0
        return TrainingStats(
            distanceMeters: matched.reduce(0) { $0 + $1.distanceMeters },
            averageHeartRate: heart,
            elevationGainMeters: matched.reduce(0) { $0 + $1.elevationGainMeters },
            averageCadence: cadence,
            count: matched.count,
            averagePaceSecPerKm: pace,
            averageStrideMeters: stride,
            averageSessionLoad: load,
            totalSessionLoad: Double(totalLoad),
            trainingScore: score
        )
    }
}
