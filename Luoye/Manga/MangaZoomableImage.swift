import SwiftUI
import UIKit

/// Native pinch/pan inertia and an anchored double-tap, shared by local and online manga pages.
struct MangaZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    func makeUIView(context: Context) -> MangaZoomView { MangaZoomView() }
    func updateUIView(_ view: MangaZoomView, context: Context) { view.setImage(image); view.onTap = onTap }
    static func dismantleUIView(_ view: MangaZoomView, coordinator: Void) { view.delegate = nil; view.onTap = {} }
}

final class MangaZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: () -> Void = {}
    private var viewport = CGSize.zero
    private var arranging = false
    private var resetOnLayout = true

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityIdentifier = "manga.zoom.viewport"
        accessibilityLabel = "漫画页面"
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 1; maximumZoomScale = 5
        bouncesZoom = true; bounces = false
        decelerationRate = .fast
        delegate = self
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        delaysContentTouches = false
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:))); doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.cancelsTouchesInView = false; doubleTap.cancelsTouchesInView = false
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap); addGestureRecognizer(singleTap)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        resetOnLayout = true
        imageView.image = image
        viewport = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !arranging, bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
        guard viewport != bounds.size else { return }
        arranging = true
        defer { arranging = false }
        let preserve = !resetOnLayout && viewport != .zero && imageView.bounds.width > 0 && imageView.bounds.height > 0
        let center = imageView.convert(CGPoint(x: contentOffset.x + viewport.width / 2, y: contentOffset.y + viewport.height / 2), from: self)
        let normalized = CGPoint(x: center.x / max(imageView.bounds.width, 1), y: center.y / max(imageView.bounds.height, 1))
        let scale = preserve ? zoomScale : minimumZoomScale
        setZoomScale(minimumZoomScale, animated: false)
        let fit = min(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
        contentSize = imageView.bounds.size
        viewport = bounds.size; resetOnLayout = false
        setZoomScale(scale, animated: false)
        centerImage()
        if preserve {
            let x = normalized.x * imageView.frame.width - bounds.width / 2
            let y = normalized.y * imageView.frame.height - bounds.height / 2
            contentOffset = CGPoint(x: min(max(x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
                                    y: min(max(y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
        } else {
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
    }

    private func centerImage() {
        accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer { return zoomScale > minimumZoomScale + 0.01 }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { if !arranging { centerImage() } }

    func toggleZoom(at point: CGPoint, animated: Bool) {
        layoutIfNeeded()
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let target = min(2, maximumZoomScale)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: animated)
        }
    }
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        toggleZoom(at: gesture.location(in: imageView), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    @objc private func handleSingleTap() { onTap() }
}
