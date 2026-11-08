import SwiftUI

/// 两种自动阅读：定时翻页，或像字幕一样连续滚动。
enum AutoMode: String {
    case pages, scroll

    var label: String {
        switch self {
        case .pages: "自动翻页"
        case .scroll: "自动滚动"
        }
    }

    // MARK: 速度
    //
    // 旋钮上统一用 0…1 表示「慢 → 快」，各模式再换算成自己的单位。

    /// 自动滚动：每分钟 4 行 … 150 行（上限）。
    static let scrollLines: ClosedRange<Double> = 4 ... 150
    /// 自动翻页：每页 60 秒 … 3 秒（最快）。
    static let pageSeconds: ClosedRange<Double> = 3 ... 60

    /// 滚动也按对数刻度：慢速区间细，快速区间粗。
    static func scrollLines(atSpeed speed: Double) -> Double {
        scrollLines.lowerBound * pow(scrollLines.upperBound / scrollLines.lowerBound, speed)
    }

    static func speed(forScrollLines lines: Double) -> Double {
        log(lines / scrollLines.lowerBound) / log(scrollLines.upperBound / scrollLines.lowerBound)
    }

    /// 翻页按对数刻度：越快越细，3–10 秒之间更好拿捏。
    static func pageSeconds(atSpeed speed: Double) -> Double {
        pageSeconds.upperBound * pow(pageSeconds.lowerBound / pageSeconds.upperBound, speed)
    }

    static func speed(forPageSeconds seconds: Double) -> Double {
        log(seconds / pageSeconds.upperBound) / log(pageSeconds.lowerBound / pageSeconds.upperBound)
    }
}

/// 调速拨盘，仿相机变焦：一段微弯的弧上排着刻度，中间一个固定的藕粉标记；
/// 手指左右滑动拨动刻度，往左加快、往右放慢，无级变化。
/// 每 5% 一道长刻度，同时震一下（力度随速度 10% → 40%）；到头时停住并轻震。
struct SpeedDial: View {
    /// 0（最慢）… 1（最快）
    @Binding var speed: Double
    let title: String
    /// 拨盘上方的读数，如「45.2」
    let reading: String
    /// 读数后面的单位，如「行 / 分钟」
    let unit: String
    /// 长刻度下方的小字：给出某个位置对应的实际速度
    let label: (Double) -> String
    var onAdjustmentChanged: (Bool) -> Void = { _ in }

    @State private var lastTranslation: CGFloat?
    @State private var tick = 0
    @State private var hitLimit = 0

    /// 每 5% 一档，与震动一一对应
    private static let detent = 0.05
    /// 整个量程分成 100 道小刻度
    private static let ticks = 100
    /// 每道小刻度在弧上占的角度
    private static let tickAngle = 1.9
    /// 弧所在的大圆半径：越大越平
    private static let radius: CGFloat = 280
    /// 手指拨过这么多点，速度走完整个量程
    private static var travel: CGFloat { radius * CGFloat(Double(ticks) * tickAngle * .pi / 180) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(reading)
                    .font(.serif(20, medium: true))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(speed >= 1 ? "最快" : speed <= 0 ? "最慢" : unit)
                    .font(.serif(10))
                    .foregroundStyle(speed >= 1 || speed <= 0 ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
            }

            Canvas { context, size in
                drawTicks(in: &context, size: size)
            }
            .frame(height: 50)
            .contentShape(.rect)
            .gesture(dragGesture)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .sensoryFeedback(trigger: tick) { _, _ in
            .impact(flexibility: .soft, intensity: 0.1 + 0.3 * speed)
        }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.4), trigger: hitLimit)
        .onDisappear { lastTranslation = nil; onAdjustmentChanged(false) }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(reading) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: speed = min(1, speed + Self.detent)
            case .decrement: speed = max(0, speed - Self.detent)
            @unknown default: break
            }
        }
    }

    private func drawTicks(in context: inout GraphicsContext, size: CGSize) {
        let arcTop: CGFloat = 14
        let center = CGPoint(x: size.width / 2, y: arcTop + Self.radius)
        let halfVisible = asin(min(1, (size.width / 2 - 34) / Self.radius)) * 180 / .pi

        for index in 0 ... Self.ticks {
            let position = Double(index) / Double(Self.ticks)
            let angle = (position - speed) * Double(Self.ticks) * Self.tickAngle
            guard abs(angle) <= halfVisible else { continue }

            let major = index % 5 == 0
            let radians = angle * .pi / 180
            let direction = CGVector(dx: sin(radians), dy: -cos(radians))
            let outer = CGPoint(x: center.x + direction.dx * Self.radius, y: center.y + direction.dy * Self.radius)
            let length: CGFloat = major ? 10 : 5
            let inner = CGPoint(x: outer.x - direction.dx * length, y: outer.y - direction.dy * length)

            // 越靠两端越淡，像弧面转到背后去；走过的刻度越靠近指针越亮。
            let distance = abs(angle) / halfVisible
            let fade = pow(1 - distance, 1.4)
            let passed = position <= speed + 0.0001
            let color = passed
                ? Color.accent.opacity(0.35 + 0.65 * fade)
                : Color.primary.opacity((major ? 0.45 : 0.25) * fade)
            var path = Path()
            path.move(to: outer)
            path.addLine(to: inner)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: major ? 1.4 : 0.8, lineCap: .round))

            if index % 25 == 0 {
                let textPoint = CGPoint(x: inner.x - direction.dx * 11, y: inner.y - direction.dy * 11)
                context.draw(
                    Text(label(position)).font(.serif(9)).foregroundStyle(Color.secondary.opacity(fade)),
                    at: textPoint
                )
            }
        }

        // 中间固定的指针：一道细细的藕粉竖线，带一点柔光。
        let needle = Path(roundedRect: CGRect(x: size.width / 2 - 1, y: arcTop - 6, width: 2, height: 20), cornerRadius: 1)
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.fill(needle, with: .color(Color.accent.opacity(0.8)))
        context.fill(needle, with: .color(Color.accent))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if lastTranslation == nil { onAdjustmentChanged(true) }
                defer { lastTranslation = value.translation.width }
                // 每次落指都重新量起，不沿用上一次的位置，免得数值跳变。
                guard value.translation != .zero, let last = lastTranslation else { return }
                let delta = value.translation.width - last

                let old = speed
                // 往左拨刻度跟着往左走，指针就落到更快的一侧。
                let new = min(1, max(0, old - Double(delta / Self.travel)))
                speed = new
                if Int(new / Self.detent) != Int(old / Self.detent) { tick += 1 }
                if (new == 1 || new == 0), new != old { hitLimit += 1 }
            }
            .onEnded { _ in lastTranslation = nil; onAdjustmentChanged(false) }
    }
}

/// 自动翻页时贴在屏幕最底部的一道细线：从左往右长满，就翻到下一页。
struct AutoPageLine: View {
    let start: Date
    let interval: TimeInterval

    var body: some View {
        VStack {
            Spacer()
            TimelineView(.animation) { context in
                let fraction = min(1, max(0, context.date.timeIntervalSince(start) / interval))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.accent.opacity(0.15))
                        Capsule().fill(Color.accent.opacity(0.7))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 2)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 6)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
