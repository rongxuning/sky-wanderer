import MapKit
import UIKit

enum SkyBasemapMode: Equatable {
    case tianditu
    case system
}

/// One switch for every phone map. An empty key starts on the system map and
/// never requests tiles. 429, a timeout, or repeated tile errors flip the same way.
final class SkyBasemapCenter: ObservableObject {
    static let shared = SkyBasemapCenter()

    @Published private(set) var mode: SkyBasemapMode

    private let lock = NSLock()
    private var otherFailures = 0
    private var gaveUp = false

    /// Maps no longer draw a provider line. Kept empty so old call sites stay quiet.
    var caption: String { "" }

    private init() {
        mode = TiandituConfig.token.isEmpty ? .system : .tianditu
        if mode == .system {
            gaveUp = true
        }
    }

    func noteFailure(_ failure: TiandituTileFailure) {
        let flip: Bool
        lock.lock()
        switch failure {
        case .rateLimited, .timeout:
            flip = !gaveUp
            gaveUp = true
        case .other:
            otherFailures += 1
            flip = otherFailures >= 4 && !gaveUp
            if flip { gaveUp = true }
        }
        lock.unlock()
        guard flip else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode != .system else { return }
            self.mode = .system
        }
    }
}

enum SkyBasemapInstaller {
    /// The stack actually drawn. `.vector` exists on `TiandituStack` and is not used here.
    static let stack: TiandituStack = .terrain

    static let backdrop = UIColor(white: 0.94, alpha: 1)

    /// Removes previous Tianditu overlays. Adds `ter_w` (replaces the basemap) and
    /// `cta_w` only while the mode is still Tianditu and a key is present.
    @discardableResult
    static func attach(to map: MKMapView, mode: SkyBasemapMode, removing existing: [MKTileOverlay]) -> [MKTileOverlay] {
        for overlay in existing {
            map.removeOverlay(overlay)
        }
        map.backgroundColor = backdrop
        guard mode == .tianditu else { return [] }
        let token = TiandituConfig.token
        guard !token.isEmpty else { return [] }
        let overlays = stack.layers.map { TiandituTileOverlay(layer: $0, token: token) }
        for overlay in overlays {
            map.addOverlay(overlay, level: .aboveRoads)
        }
        return overlays
    }
}

enum MapLegalChrome {
    /// Hides MapKit's 法律信息 / 高德地图 line and any other provider mark.
    /// Used on full-screen maps, share snapshots, and list thumbnails alike.
    static func hideProviderChrome(on map: MKMapView) {
        hideThumbnailChrome(on: map)
    }

    static func setAppleAttributionHidden(_ hidden: Bool, on map: MKMapView) {
        if hidden {
            hideProviderChrome(on: map)
            return
        }
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("Attribution") {
                view.isHidden = false
                view.alpha = 1
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(map)
    }

    /// Hides 法律信息, the 高德地图 mark, and any other attribution or logo view.
    static func hideThumbnailChrome(on map: MKMapView) {
        func conceal(_ view: UIView) {
            guard !view.isHidden else { return }
            view.isHidden = true
            view.alpha = 0
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }
        func walk(_ view: UIView) {
            for child in view.subviews {
                if hidesThumbnailChrome(child) || isCornerChrome(child, in: map) {
                    conceal(child)
                }
                walk(child)
            }
        }
        walk(map)
    }

    /// Small direct children along the bottom edge. 法律信息 and the provider
    /// mark sit here, sometimes beside the attribution label rather than inside it.
    /// A view that has not been laid out yet, or that fills the map, stays visible.
    private static func isCornerChrome(_ view: UIView, in map: MKMapView) -> Bool {
        guard view.superview === map else { return false }
        let bounds = map.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        let frame = view.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let small = frame.width < bounds.width * 0.85 && frame.height < bounds.height * 0.5
        let alongBottom = frame.midY > bounds.height * 0.5
        guard small, alongBottom else { return false }
        let name = String(describing: type(of: view))
        if name.contains("Container") || name.contains("Overlay") || name.contains("Annotation") || name.contains("Content") {
            return false
        }
        return true
    }

    private static func hidesThumbnailChrome(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        if name.contains("Attribution") || name.contains("Logo") || name.contains("Legal") {
            return true
        }
        let text = labelText(view) + " " + (view.accessibilityLabel ?? "")
        if text.contains("法律") || text.contains("高德") || text.contains("系统地图") || text.contains("天地图") {
            return true
        }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.contains("legal") || folded.contains("amap") || folded.contains("gaode")
    }

    private static func labelText(_ view: UIView) -> String {
        guard let label = view as? UILabel else { return "" }
        if let text = label.text, !text.isEmpty { return text }
        return label.attributedText?.string ?? ""
    }
}

/// Small capsule used on the map and burned into share images.
final class BasemapCreditLabel: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        label.textAlignment = .center
        label.isAccessibilityElement = false
        backgroundColor = UIColor.white.withAlphaComponent(0.92)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setText(_ text: String?) {
        let shown = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isHidden = shown.isEmpty
        label.text = shown
        isAccessibilityElement = !shown.isEmpty
        accessibilityLabel = shown
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: 280, height: 20))
        return CGSize(width: min(280, ceil(text.width) + 20), height: 22)
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(.zero)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 10, dy: 3)
        layer.cornerRadius = bounds.height / 2
    }
}
