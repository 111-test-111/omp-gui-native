import SwiftUI

/// Finite, presentation-only motion. Chart values, scales, hit testing and layout
/// stay on the accepted snapshot throughout the reveal.
enum UsageRevealStyle {
    case fade, text, bars, ring, sweep
}

extension View {
    func usageReveal<Trigger: Equatable>(trigger: Trigger, active: Bool, style: UsageRevealStyle = .fade,
                                         delay: Double = 0) -> some View {
        modifier(UsageReveal(trigger: trigger, active: active, style: style, delay: delay))
    }
}

private struct UsageReveal<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let active: Bool
    let style: UsageRevealStyle
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var progress = 1.0

    private struct Replay: Equatable {
        let trigger: Trigger
        let active: Bool
        let enabled: Bool
    }

    func body(content: Content) -> some View {
        let enabled = !reduceMotion && !performanceMode
        Group {
            if enabled {
                content.modifier(UsageRevealDrawing(progress: progress, style: style))
            } else {
                content
            }
        }
        .task(id: Replay(trigger: trigger, active: active, enabled: enabled)) {
            guard active, enabled else { reset(to: 1); return }
            reset(to: 0)
            // Give the initial state one display opportunity; this cancellable
            // delay runs only on entry or an explicit presentation change.
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 0.75, 0.25, 1, duration: 0.65).delay(delay)) {
                progress = 1
            }
        }
        .onDisappear { reset(to: 1) }
    }

    private func reset(to value: Double) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = value }
    }
}

private struct UsageRevealDrawing: ViewModifier, Animatable {
    var progress: Double
    let style: UsageRevealStyle

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let amount = min(1, max(0, progress))
        switch style {
        case .fade:
            content.opacity(0.25 + 0.75 * amount).offset(y: 6 * (1 - amount))
        case .text:
            content.opacity(0.25 + 0.75 * amount)
        case .bars:
            content
                .scaleEffect(x: 1, y: 0.94 + 0.06 * amount, anchor: .bottom)
                .mask { sweep(amount) }
        case .ring:
            content
                .mask {
                    ZStack {
                        Color.white.opacity(0.14)
                        AngularGradient(stops: stops(amount), center: .center,
                                        startAngle: .degrees(-90), endAngle: .degrees(270))
                    }
                }
                .scaleEffect(0.94 + 0.06 * amount)
        case .sweep:
            content.mask { sweep(amount) }
        }
    }

    private func sweep(_ amount: Double) -> some View {
        ZStack {
            Color.white.opacity(0.14)
            LinearGradient(stops: stops(amount), startPoint: .leading, endPoint: .trailing)
        }
    }

    private func stops(_ amount: Double) -> [Gradient.Stop] {
        [.init(color: .white, location: 0),
         .init(color: .white, location: max(0, min(1, amount * 1.16 - 0.16))),
         .init(color: .clear, location: max(0, min(1, amount * 1.16)))]
    }
}
