import SwiftUI

struct SportRouletteOverlay: View {
    var sports: [SportKind] = Array(SportKind.allCases)
    @Binding var selection: SportKind
    var screenWidth: CGFloat
    var screenHeight: CGFloat
    var onDismiss: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var pendingTapCommit: DispatchWorkItem?
    @State private var pendingTapIndex: Int?

    private let springResponse: Double = 0.38
    private var itemCount: Int { sports.count }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            ForEach(Array(sports.enumerated()).filter { index, _ in isRendered(index) }, id: \.element.id) { index, sport in
                item(sport: sport, index: index)
            }
        }
        .onAppear {
            if let idx = sports.firstIndex(of: selection) {
                scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: idx))
            }
        }
        .onDisappear(perform: flushPendingTapCommit)
        .highPriorityGesture(drag)
    }

    private func isRendered(_ index: Int) -> Bool {
        let angle = SportRouletteGeometry.angle(forIndex: index, scrollOffset: ChromeLength(scrollOffset))
        return SportRouletteGeometry.isRendered(angle: angle)
    }

    @ViewBuilder
    private func item(sport: SportKind, index: Int) -> some View {
        let angle = SportRouletteGeometry.angle(forIndex: index, scrollOffset: ChromeLength(scrollOffset))
        let point = SportRouletteGeometry.position(
            index: index,
            scrollOffset: ChromeLength(scrollOffset),
            screenWidth: ChromeLength(screenWidth),
            screenHeight: ChromeLength(screenHeight)
        )
        let scale = CGFloat(SportRouletteGeometry.scale(forAngle: angle))
        let opacity = CGFloat(SportRouletteGeometry.opacity(forAngle: angle))
        let dot = CGFloat(SportRouletteGeometry.dotDiameter)
        let onMidline = SportRouletteGeometry.isOnMidline(angle: angle)

        Button {
            tap(index, onMidline: onMidline)
        } label: {
            ZStack {
                Circle()
                    .fill(SkyTheme.Color.starryGray)
                    .frame(width: dot, height: dot)
                Image(systemName: sport.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.onStarryGray)
            }
            .overlay(alignment: .leading) {
                Text(sport.title)
                    .font(.system(size: 16, weight: onMidline ? .semibold : .regular))
                    .foregroundStyle(SkyTheme.Color.ink)
                    .fixedSize()
                    .padding(.leading, dot + SkyTheme.Spacing.related)
            }
            .scaleEffect(scale, anchor: .center)
            .opacity(opacity)
        }
        .buttonStyle(.plain)
        .position(x: CGFloat(point.x), y: CGFloat(point.y))
        .zIndex(1000 - abs(Double(angle)))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 9)
            .onChanged { value in
                if dragOrigin == nil {
                    cancelPendingTapCommit()
                    dragOrigin = scrollOffset
                }
                let origin = dragOrigin ?? scrollOffset
                let deltaIndex = -value.translation.height / CGFloat(SportRouletteGeometry.dragPixelsPerStep)
                scrollOffset = CGFloat(
                    SportRouletteGeometry.clampedScrollOffset(
                        ChromeLength(origin + deltaIndex),
                        itemCount: itemCount
                    )
                )
            }
            .onEnded { value in
                let origin = dragOrigin ?? scrollOffset
                dragOrigin = nil
                let projected = origin
                    - value.predictedEndTranslation.height / CGFloat(SportRouletteGeometry.dragPixelsPerStep)
                let nearest = SportRouletteGeometry.nearestIndex(
                    scrollOffset: ChromeLength(projected),
                    itemCount: itemCount
                )
                withAnimation(.spring(response: springResponse, dampingFraction: 0.86)) {
                    scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: nearest))
                }
                commit(nearest)
            }
    }

    private func tap(_ index: Int, onMidline: Bool) {
        // Selected midline item dismisses, same as tapping the mask.
        if onMidline {
            cancelPendingTapCommit()
            onDismiss()
            return
        }
        cancelPendingTapCommit()
        withAnimation(.spring(response: springResponse, dampingFraction: 0.86)) {
            scrollOffset = CGFloat(SportRouletteGeometry.scrollOffset(centering: index))
        }
        scheduleTapCommit(index)
    }

    private func cancelPendingTapCommit() {
        pendingTapCommit?.cancel()
        pendingTapCommit = nil
        pendingTapIndex = nil
    }

    private func flushPendingTapCommit() {
        guard let index = pendingTapIndex else { return }
        cancelPendingTapCommit()
        commit(index)
    }

    private func scheduleTapCommit(_ index: Int) {
        let work = DispatchWorkItem {
            pendingTapCommit = nil
            pendingTapIndex = nil
            commit(index)
        }
        pendingTapCommit = work
        pendingTapIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + springResponse, execute: work)
    }

    private func commit(_ index: Int) {
        guard sports.indices.contains(index) else { return }
        selection = sports[index]
    }
}
