import SwiftUI
import UIKit

struct PageWheelEntry: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
}

/// Screen-space dial math. Positive rotation moves items clockwise.
enum PageWheelMath {
    static func step(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return (2 * Double.pi) / Double(count)
    }

    static func selectedIndex(count: Int, rotation: Double) -> Int {
        guard count > 0 else { return 0 }
        let raw = (-rotation / step(count: count)).rounded()
        let wrapped = Int(raw) % count
        return wrapped >= 0 ? wrapped : wrapped + count
    }

    /// Angle on screen: 0 is right, positive is clockwise, `-π/2` is the top slot.
    static func visualAngle(index: Int, count: Int, rotation: Double) -> Double {
        (-.pi / 2) + (Double(index) * step(count: count)) + rotation
    }

    /// Positive when the finger moves clockwise around `center`.
    static func clockwiseDelta(from start: CGPoint, to end: CGPoint, center: CGPoint) -> Double {
        let startAngle = atan2(Double(start.y - center.y), Double(start.x - center.x))
        let endAngle = atan2(Double(end.y - center.y), Double(end.x - center.x))
        return wrap(endAngle - startAngle)
    }

    static func snap(base: Double, delta: Double, momentum: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let step = step(count: count)
        let flicked = abs(momentum) > 0.55 && abs(delta) < step * 0.45
        if flicked {
            let direction: Double = momentum > 0 ? 1 : -1
            return (base / step).rounded() * step + direction * step
        }
        let limited = min(max(momentum, -step * 1.25), step * 1.25)
        return ((base + delta + limited * 0.55) / step).rounded() * step
    }

    static func wrap(_ angle: Double) -> Double {
        let cycle = 2 * Double.pi
        var value = angle.truncatingRemainder(dividingBy: cycle)
        if value > .pi { value -= cycle }
        if value <= -.pi { value += cycle }
        return value
    }
}

struct PageWheel: View {
    var entries: [PageWheelEntry]
    var onSelect: (PageWheelEntry) -> Void
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0
    @State private var gestureBase = 0.0
    @State private var gestureArmed = false

    private let disc: CGFloat = 300
    private let orbit: CGFloat = 104
    private let iconSide: CGFloat = 46
    private let hubRadius: CGFloat = 64

    private var center: CGPoint {
        CGPoint(x: disc / 2, y: disc / 2)
    }

    private var selectedIndex: Int {
        PageWheelMath.selectedIndex(count: entries.count, rotation: rotation)
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 16) {
                dial
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SkyHomeColor.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(SkyHomeColor.page, in: Capsule())
                        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消")
            }
        }
    }

    private var dial: some View {
        let current = entries[selectedIndex]
        return ZStack {
            Circle()
                .fill(SkyHomeColor.page)
                .shadow(color: Color.black.opacity(0.12), radius: 24, y: 12)
                .frame(width: disc, height: disc)
                .allowsHitTesting(false)
            Circle()
                .stroke(SkyHomeColor.secondary.opacity(0.22), lineWidth: 1)
                .frame(width: orbit * 2, height: orbit * 2)
                .allowsHitTesting(false)
            Capsule()
                .fill(SkyHomeColor.ink)
                .frame(width: 4, height: 8)
                .offset(y: -disc / 2 + 12)
                .allowsHitTesting(false)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                item(entry, index: index)
            }
            VStack(spacing: 6) {
                Text(current.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SkyHomeColor.ink)
                Text(current.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SkyHomeColor.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(width: 124)
                Text("进入")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SkyHomeColor.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(SkyHomeColor.chip, in: Capsule())
            }
            .allowsHitTesting(false)
        }
        .frame(width: disc, height: disc)
        .contentShape(Circle())
        .gesture(drag)
        .accessibilityRepresentation {
            VStack {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        Text("\(entry.title)，\(entry.subtitle)")
                    }
                    .accessibilityAddTraits(index == selectedIndex ? .isSelected : AccessibilityTraits())
                }
            }
        }
    }

    private func item(_ entry: PageWheelEntry, index: Int) -> some View {
        let selected = index == selectedIndex
        let angle = PageWheelMath.visualAngle(index: index, count: entries.count, rotation: rotation)
        return ZStack {
            Image(systemName: entry.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? Color.white : SkyHomeColor.ink)
                .frame(width: iconSide, height: iconSide)
                .background(selected ? entry.tint : SkyHomeColor.chip, in: Circle())
                .scaleEffect(selected ? 1.08 : 1)
            Text(entry.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? SkyHomeColor.ink : SkyHomeColor.secondary)
                .offset(y: iconSide / 2 + 12)
        }
        .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
        .zIndex(selected ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.74), value: selected)
        .allowsHitTesting(false)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if !gestureArmed {
                    guard moved >= 1 else { return }
                    gestureArmed = true
                    gestureBase = rotation
                }
                guard !isHub(value.startLocation) else { return }
                let delta = PageWheelMath.clockwiseDelta(from: value.startLocation, to: value.location, center: center)
                setRotation(gestureBase + delta, animated: false)
            }
            .onEnded { value in
                defer { gestureArmed = false }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 12 {
                    if gestureArmed {
                        setRotation(gestureBase, animated: true)
                    }
                    resolveTap(value.startLocation)
                    return
                }
                guard !isHub(value.startLocation) else { return }
                let delta = PageWheelMath.clockwiseDelta(from: value.startLocation, to: value.location, center: center)
                let momentum = PageWheelMath.clockwiseDelta(from: value.location, to: value.predictedEndLocation, center: center)
                let target = PageWheelMath.snap(
                    base: gestureBase,
                    delta: delta,
                    momentum: momentum,
                    count: entries.count
                )
                setRotation(target, animated: true)
            }
    }

    private func isHub(_ point: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= hubRadius
    }

    private func resolveTap(_ point: CGPoint) {
        if isHub(point) {
            commit(selectedIndex)
            return
        }
        for index in entries.indices {
            let angle = PageWheelMath.visualAngle(index: index, count: entries.count, rotation: rotation)
            let itemCenter = CGPoint(
                x: center.x + CGFloat(cos(angle)) * orbit,
                y: center.y + CGFloat(sin(angle)) * orbit
            )
            if hypot(point.x - itemCenter.x, point.y - itemCenter.y) <= 40 {
                commit(index)
                return
            }
        }
    }

    private func commit(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        onSelect(entries[index])
    }

    private func setRotation(_ value: Double, animated: Bool) {
        let next = PageWheelMath.selectedIndex(count: entries.count, rotation: value)
        if next != selectedIndex {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        if animated {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.8)) {
                rotation = value
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rotation = value
            }
        }
    }
}
