import SwiftUI

/// Studio colors drawn from the CameraCue icon. Reading surfaces stay dark
/// so script text remains easy to read close to the camera.
enum CuePalette {
    static let canvas = Color(red: 0.985, green: 0.976, blue: 0.997)
    static let sidebar = Color(red: 0.960, green: 0.947, blue: 0.985)
    static let surface = Color(red: 1.000, green: 0.997, blue: 1.000)
    static let ink = Color(red: 0.205, green: 0.165, blue: 0.300)
    static let mutedInk = Color(red: 0.405, green: 0.365, blue: 0.495)
    static let violet = Color(red: 0.455, green: 0.335, blue: 0.735)
    static let lavender = Color(red: 0.790, green: 0.710, blue: 0.970)
    static let lavenderWash = Color(red: 0.940, green: 0.905, blue: 0.995)
    static let cream = Color(red: 1.000, green: 0.971, blue: 0.898)
    static let coral = Color(red: 1.000, green: 0.535, blue: 0.445)
    static let peach = Color(red: 1.000, green: 0.823, blue: 0.758)
    static let mint = Color(red: 0.722, green: 0.935, blue: 0.832)
    static let sky = Color(red: 0.753, green: 0.878, blue: 0.995)
    static let butter = Color(red: 1.000, green: 0.906, blue: 0.690)
    static let outline = Color(red: 0.844, green: 0.798, blue: 0.914)
}

struct CueCardButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(focused || hovered ? CuePalette.violet.opacity(focused ? 1 : 0.5) : .clear, lineWidth: focused ? 2 : 1))
            .onHover { hovered = $0 }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CueSidebarButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? CuePalette.violet : .clear, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CueDashboardRowStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || configuration.isPressed || focused ? CuePalette.lavenderWash : .clear)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? CuePalette.violet : .clear, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
