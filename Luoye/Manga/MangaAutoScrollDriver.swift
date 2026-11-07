import SwiftUI
import UIKit

/// Installed inside the reader's scroll content, so it always controls that scroll view.
struct MangaAutoScrollDriver: UIViewRepresentable {
    @Environment(\.mangaScrollInteraction) private var interaction
    let pointsPerSecond: Double
    var readyToScroll = true
    var contentReady = false
    var onReachEnd: () -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.speed = readyToScroll ? max(0, min(pointsPerSecond, 200)) : 0
        view.contentReady = contentReady
        view.onReachEnd = onReachEnd
        view.onAdvance = { interaction?.advanced = true }
        view.refresh()
    }
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.stop() }

    @MainActor final class Probe: UIView {
        var speed = 0.0
        var onReachEnd: (() -> Void)?
        var onAdvance: (() -> Void)?
        private var advanced = false
        private weak var scroll: UIScrollView?
        private var link: CADisplayLink?
        private var timestamp: CFTimeInterval?
        var contentReady = false
        private var endState = MangaScrollEndState()
        private let ticker = Ticker()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            ticker.probe = self
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
        override func layoutSubviews() { super.layoutSubviews(); if speed > 0 { refresh() } }
        func refresh() {
            guard window != nil, speed > 0 else { stop(); endState.reset(); return }
            if scroll == nil {
                var ancestor = superview
                while let value = ancestor {
                    if let candidate = value as? UIScrollView { scroll = candidate; break }
                    ancestor = value.superview
                }
            }
            guard scroll != nil, link == nil else { return }
            let next = CADisplayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            next.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            next.add(to: .main, forMode: .common)
            link = next
        }
        func stop() { link?.invalidate(); link = nil; timestamp = nil; advanced = false }
        fileprivate func tick(_ link: CADisplayLink) {
            guard let scroll, window != nil, speed > 0 else { stop(); return }
            let elapsed = min(max(link.timestamp - (timestamp ?? link.timestamp), 0), 0.05)
            timestamp = link.timestamp
            guard UIApplication.shared.applicationState == .active,
                  !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { endState.reset(); return }
            let start = -scroll.adjustedContentInset.top
            let end = max(start, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            guard scroll.bounds.height > 0, scroll.contentSize.height > 0 else { return }
            let current = max(start, scroll.contentOffset.y)
            let next = min(end, current + speed * elapsed)
            if next > current && !advanced { advanced = true; onAdvance?() }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            if endState.update(atEnd: next >= end - 0.5, contentReady: contentReady, elapsed: elapsed) {
                onReachEnd?()
            }
        }
        @MainActor private final class Ticker: NSObject {
            weak var probe: Probe?
            @objc func tick(_ link: CADisplayLink) { probe?.tick(link) }
        }
    }
}

struct MangaAutoReadingControl: View {
    let kind: AutoMode
    var onShowControls: () -> Void
    var onStop: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onShowControls) { Label(kind.label, systemImage: "dial.medium").font(.serif(12)).padding(.leading, 15).padding(.trailing, 8).frame(height: 42) }
            Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 40, height: 42) }.accessibilityLabel("停止自动阅读")
        }.buttonStyle(.plain).foregroundStyle(Color.ink).paperGlass(.paper)
            .padding(.horizontal, 20).padding(.bottom, 26)
    }
}
