import AppKit
import SwiftUI

enum Mono {
    static let canvas = dynamic(light: 0xF4F4F2, dark: 0x0B0B0B)
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x151515)
    static let panelRaised = dynamic(light: 0xFAFAF8, dark: 0x1D1D1D)
    static let text = dynamic(light: 0x111111, dark: 0xF2F2F0)
    static let secondaryText = dynamic(light: 0x686866, dark: 0xA5A5A1)
    static let tertiaryText = dynamic(light: 0x92928E, dark: 0x73736F)
    static let line = dynamic(light: 0xDEDEDA, dark: 0x30302E)
    static let subtleLine = dynamic(light: 0xEAEAE7, dark: 0x252523)
    static let fill = dynamic(light: 0xECECE9, dark: 0x252523)
    static let inverse = dynamic(light: 0x111111, dark: 0xF1F1EF)
    static let inverseText = dynamic(light: 0xFFFFFF, dark: 0x111111)

    static let corner: CGFloat = 14
    static let smallCorner: CGFloat = 9
    static let sidebarWidth: CGFloat = 218
    static let libraryWidth: CGFloat = 430

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct MonoCard<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Mono.panel)
            .clipShape(RoundedRectangle(cornerRadius: Mono.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Mono.corner, style: .continuous)
                    .stroke(Mono.subtleLine, lineWidth: 1)
            }
            .motionHover()
    }
}

struct MonoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Mono.inverseText)
            .padding(.horizontal, 17)
            .frame(height: 38)
            .background(Mono.inverse.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Mono.smallCorner, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                AppMotion.resolved(AppMotion.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct MonoSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Mono.text)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(configuration.isPressed ? Mono.fill : Mono.panel)
            .clipShape(RoundedRectangle(cornerRadius: Mono.smallCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Mono.smallCorner, style: .continuous)
                    .stroke(Mono.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(
                AppMotion.resolved(AppMotion.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct MonoIconButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Mono.text)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Mono.fill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .rotationEffect(.degrees(configuration.isPressed && !reduceMotion ? -3 : 0))
            .animation(
                AppMotion.resolved(AppMotion.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct MonoSectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(Mono.tertiaryText)
    }
}

struct MonoBadge: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(inverted ? Mono.inverseText : Mono.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(inverted ? Mono.inverse : Mono.fill)
            .clipShape(Capsule())
    }
}

struct MonoToggle: View {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(AppMotion.resolved(AppMotion.selection, reduceMotion: reduceMotion)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Mono.inverse : Mono.fill)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(isOn ? Mono.inverseText : Mono.tertiaryText)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
        }
        .buttonStyle(MotionPlainButtonStyle())
        .accessibilityValue(isOn ? "On" : "Off")
        .motionAnimate(value: isOn, animation: AppMotion.selection)
    }
}

struct MonoDivider: View {
    var body: some View {
        Rectangle()
            .fill(Mono.subtleLine)
            .frame(height: 1)
    }
}

extension View {
    func monoWindowBackground() -> some View {
        background(Mono.canvas)
            .preferredColorScheme(nil)
    }
}
