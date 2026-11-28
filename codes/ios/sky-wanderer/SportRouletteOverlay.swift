import SwiftUI

/// One node on the sport-type roulette. Training uses every `SportKind`;
/// the records filter prepends ``all``.
struct SportRouletteItem: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var symbol: String

    static let all = SportRouletteItem(
        id: "all",
        title: "全部",
        symbol: "square.grid.2x2"
    )

    static func sport(_ kind: SportKind) -> SportRouletteItem {
        SportRouletteItem(id: kind.id, title: kind.title, symbol: kind.symbol)
    }
}

struct SportRouletteOverlay: View {
    var items: [SportRouletteItem]
    @Binding var selectionID: String
    var screenWidth: CGFloat
    var screenHeight: CGFloat
    var onDismiss: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var pendingTapCommit: DispatchWorkItem?
    @State private var pendingTapIndex: Int?

    private var springResponse: Double { Double(SportRouletteGeometry.snapSpringResponse) }
    private var itemCount: Int { items.count }

    /// Training start map: every sport, selection is `SportKind`.
    init(
        selection: Binding<SportKind>,
        sports: [SportKind] = Array(SportKind.allCases),
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.items = sports.map(SportRouletteItem.sport)
        self._selectionID = Binding(
            get: { selection.wrappedValue.id },
            set: { id in
                if let sport = sports.first(where: { $0.id == id }) {
                    selection.wrappedValue = sport
                }
            }
        )
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.onDismiss = onDismiss
    }

    /// Records filter: ``SportRouletteItem/all`` plus the sports that appear in the log.
    init(
        filter: Binding<SportKind?>,
        sports: [SportKind],
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.items = [SportRouletteItem.all] + sports.map(SportRouletteItem.sport)
        self._selectionID = Binding(
            get: { filter.wrappedValue?.id ?? SportRouletteItem.all.id },
            set: { id in
                if id == SportRouletteItem.all.id {
                    filter.wrappedValue = nil
                } else {
                    filter.wrappedValue = sports.first(where: { $0.id == id })
                }
            }
        )
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.onDismiss = onDismiss
    }

    init(
        items: [SportRouletteItem],
        selectionID: Binding<String>,
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self._selectionID = selectionID
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            ForEach(Array(items.enumerated()).filter { index, _ in isRendered(index) }, id: \.element.id) { index, item in
                row(item: item, index: index)
            }
        }
        .onAppear {
            if let idx = items.firstIndex(where: { $0.id == selectionID }) {
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
    private func row(item: SportRouletteItem, index: Int) -> some View {
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
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SkyTheme.Color.onStarryGray)
            }
            .overlay(alignment: .leading) {
                Text(item.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SkyTheme.Color.onPrimary)
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
        guard items.indices.contains(index) else { return }
        selectionID = items[index].id
    }
}
