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

    /// Screens use this. Route detail keeps the string above the title as well.
    var caption: String {
        switch mode {
        case .tianditu:
            return TiandituConfig.credit
        case .system:
            return "系统地图"
        }
    }

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
    static func setAppleAttributionHidden(_ hidden: Bool, on map: MKMapView) {
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("Attribution") {
                view.isHidden = hidden
                view.alpha = hidden ? 0 : 1
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(map)
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
