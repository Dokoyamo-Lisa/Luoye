#if DEBUG
import UIKit

@MainActor enum MangaZoomVerification {
    static func run() {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) { checks.append(["passed": value, "title": title]); print("MANGA_ZOOM \(value ? "PASS" : "FAIL") \(title)") }
        func image(_ color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900)) }
        }
        func center(_ view: MangaZoomView) -> CGPoint {
            let point = view.imageView.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            return CGPoint(x: point.x / view.imageView.bounds.width, y: point.y / view.imageView.bounds.height)
        }
        let a = image(.systemPink), b = image(.systemBlue), view = MangaZoomView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        view.setImage(a); view.layoutIfNeeded()
        check(view.zoomScale == 1 && abs(view.imageView.frame.width - 390) < 1 && abs(view.imageView.frame.height - 585) < 1, "initial image fits the viewport without stretching")
        check(!view.gestureRecognizerShouldBegin(view.panGestureRecognizer) && abs(view.contentInset.top - view.contentInset.bottom) < 1, "base image centers and yields panning to the page reader")
        view.toggleZoom(at: CGPoint(x: view.imageView.bounds.midX, y: view.imageView.bounds.midY), animated: false)
        check(abs(view.zoomScale - 2) < 0.01 && view.gestureRecognizerShouldBegin(view.panGestureRecognizer), "double tap zooms to two-times scale and enables native panning")
        let before = center(view)
        check(abs(before.x - 0.5) < 0.02 && abs(before.y - 0.5) < 0.02, "double tap preserves the tapped image center")
        view.setImage(a); view.layoutIfNeeded()
        check(abs(view.zoomScale - 2) < 0.01, "menu updates with the same image do not reset zoom")
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 390); view.layoutIfNeeded()
        let after = center(view)
        check(abs(view.zoomScale - 2) < 0.01 && abs(before.x - after.x) < 0.03 && abs(before.y - after.y) < 0.03, "rotation preserves zoom and image-center anchor")
        view.toggleZoom(at: .zero, animated: false)
        check(abs(view.zoomScale - 1) < 0.01 && !view.gestureRecognizerShouldBegin(view.panGestureRecognizer), "double tap restores base scale and page swiping")
        view.setZoomScale(4, animated: false); view.setImage(b); view.layoutIfNeeded()
        check(view.zoomScale == 1 && view.imageView.image === b && !view.gestureRecognizerShouldBegin(view.panGestureRecognizer), "changing pages resets zoom without retaining the old image")
        check(view.pinchGestureRecognizer?.isEnabled == true, "pinch remains available while base-scale scrolling is delegated")
        let taps = view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        check(Set(taps.map(\.numberOfTapsRequired)) == [1, 2], "native single and double tap recognizers are installed separately")
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeMangaZoomVerification.json"), options: .atomic) }
        view.delegate = nil
    }
}
#endif
