import SwiftUI

enum AppMotion {
    static let quick = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeInOut(duration: 0.24)
    static let expressive = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let selection = Animation.spring(response: 0.3, dampingFraction: 0.86)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

struct MotionPlainButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                AppMotion.resolved(AppMotion.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

private struct MotionAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    let delay: Double
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .scaleEffect(visible || reduceMotion ? 1 : 0.985)
            .onAppear {
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(AppMotion.expressive.delay(delay)) {
                        visible = true
                    }
                }
            }
            .onDisappear { visible = false }
    }
}

private struct MotionHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let lift: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: hovering && !reduceMotion ? -lift : 0)
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(
                color: Color.black.opacity(hovering && !reduceMotion ? 0.12 : 0),
                radius: hovering && !reduceMotion ? 16 : 0,
                y: hovering && !reduceMotion ? 7 : 0
            )
            .onHover { value in
                withAnimation(AppMotion.resolved(AppMotion.selection, reduceMotion: reduceMotion)) {
                    hovering = value
                }
            }
    }
}

private struct MotionValueModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(
            AppMotion.resolved(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}

private struct MotionPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active && pulsing && !reduceMotion ? 0.48 : 1)
            .scaleEffect(active && pulsing && !reduceMotion ? 0.94 : 1)
            .onAppear { updatePulse() }
            .onChange(of: active) { _ in updatePulse() }
    }

    private func updatePulse() {
        guard active, !reduceMotion else {
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

extension View {
    func motionAppear(delay: Double = 0, distance: CGFloat = 10) -> some View {
        modifier(MotionAppearModifier(delay: delay, distance: distance))
    }

    func motionHover(lift: CGFloat = 2, scale: CGFloat = 1.006) -> some View {
        modifier(MotionHoverModifier(lift: lift, scale: scale))
    }

    func motionAnimate<Value: Equatable>(
        value: Value,
        animation: Animation = AppMotion.standard
    ) -> some View {
        modifier(MotionValueModifier(value: value, animation: animation))
    }

    func motionPulse(active: Bool = true) -> some View {
        modifier(MotionPulseModifier(active: active))
    }
}
