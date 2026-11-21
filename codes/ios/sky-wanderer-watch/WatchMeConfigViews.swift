import SwiftUI

enum WatchMePush: Hashable {
    case health
    case trainingAuthorization
    case notifications
    case sdkList
}

struct WatchMeHomeView: View {
    @EnvironmentObject private var app: WatchAppState

    private var estimate: TrainingEstimateSummary {
        app.estimate()
    }

    var body: some View {
        List {
            Section("健康与训练") {
                NavigationLink(value: WatchMePush.health) {
                    Label("健康", systemImage: "heart")
                }
                NavigationLink(value: WatchMePush.trainingAuthorization) {
                    Label("训练授权", systemImage: "figure.run")
                }
            }
            Section("隐私") {
                NavigationLink(value: WatchMePush.notifications) {
                    Label("通知设置", systemImage: "bell")
                }
                NavigationLink(value: WatchMePush.sdkList) {
                    Label("第三方 SDK 清单", systemImage: "list.bullet.rectangle")
                }
            }
            Section("训练估计") {
                Text("体能储备 \(estimate.reserve)")
                Text("训练负荷 \(estimate.recentLoad)")
                Text(estimate.restHint)
                Text("不是医疗建议")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
            }
        }
        .navigationTitle("我的")
        .navigationDestination(for: WatchMePush.self) { push in
            switch push {
            case .health:
                WatchMeHealthView()
            case .trainingAuthorization:
                WatchMeTrainingAuthView()
            case .notifications:
                WatchMeNotificationsView()
            case .sdkList:
                WatchMeSDKListView()
            }
        }
    }
}

struct WatchMeHealthView: View {
    @State private var heart = 72.0
    @State private var sleep = 7.4
    @State private var steps = 6420
    @State private var heartSample = true
    @State private var sleepSample = true
    @State private var stepsSample = true
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniMuted)
            }
            LabeledContent("心率") {
                Text("\(Int(heart.rounded()))\(heartSample ? " 示例" : "")")
                    .foregroundStyle(Color.skyMetricHeart)
            }
            LabeledContent("睡眠") {
                Text(String(format: "%.1f 小时%@", sleep, sleepSample ? " 示例" : ""))
            }
            LabeledContent("步数") {
                Text("\(steps)\(stepsSample ? " 示例" : "")")
            }
            Button("重新读取") {
                Task { await reload() }
            }
        }
        .navigationTitle("健康")
        .task { await reload() }
    }

    private func reload() async {
        guard AppleHealth.available else {
            note = "这台设备没有健康数据，下面是示例。"
            return
        }
        do {
            try await AppleHealth.authorize()
        } catch {
            note = "健康授权没有完成，下面是示例。"
            return
        }
        note = ""
        let day = await AppleHealth.today()
        if let value = day.heartRate, value > 0 {
            heart = value
            heartSample = false
        }
        if let value = day.sleepHours, value > 0 {
            sleep = value
            sleepSample = false
        }
        if let value = day.steps {
            steps = value
            stepsSample = false
        }
    }
}

struct WatchMeTrainingAuthView: View {
    @State private var status = MeTrainingShareState.notDetermined
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Text(status.title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
            Text(status.detail)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
            Button(busy ? "请求中" : "请求授权") {
                request()
            }
            .disabled(busy || status == .unavailable)
            if let message {
                Text(message)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.omniCobalt)
            }
        }
        .navigationTitle("训练授权")
        .task { status = AppleHealth.workoutShareAuthorization() }
    }

    private func request() {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await AppleHealth.authorize()
                message = "已向系统请求授权。"
            } catch {
                message = "这台设备没有健康数据，授权请求没有发出。"
            }
            status = AppleHealth.workoutShareAuthorization()
        }
    }
}

struct WatchMeNotificationsView: View {
    var body: some View {
        List {
            ForEach(MeNotificationPreference.allCases) { kind in
                Toggle(isOn: binding(kind)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.detail)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.omniMuted)
                    }
                }
            }
            Text(MeProfileCopy.notificationFootnote)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
        }
        .navigationTitle("通知设置")
    }

    private func binding(_ kind: MeNotificationPreference) -> Binding<Bool> {
        Binding(
            get: { kind.isOn() },
            set: { kind.setOn($0) }
        )
    }
}

struct WatchMeSDKListView: View {
    var body: some View {
        List {
            Text(MeSDKCatalog.intro)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.omniMuted)
            ForEach(MeSDKCatalog.services) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(entry.purpose)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.omniCobalt)
                    Text(entry.data)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.omniMuted)
                }
            }
        }
        .navigationTitle("第三方 SDK")
    }
}
