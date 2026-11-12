import SwiftUI

struct StudioButtonStyle: ButtonStyle {
    var light = false
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration, light: light, radius: radius) }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let light: Bool
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .background(RoundedRectangle(cornerRadius: radius).fill((light ? Color.white : StudioTheme.cyan).opacity(enabled ? (configuration.isPressed ? 0.23 : hovered ? 0.13 : 0) : 0)))
                .brightness(enabled && hovered ? 0.035 : 0)
                .opacity(enabled ? 1 : 0.42)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}
