import SwiftUI

/// Runtime-variable theme state (§2.3): resolved accessibility flags ride the
/// environment so previews can force any combination. Static tokens stay on
/// `DS` — only what can vary at runtime lives here.
public struct Theme: Sendable, Equatable {
    public var reduceMotion: Bool
    public var reduceTransparency: Bool
    public var increaseContrast: Bool

    public init(reduceMotion: Bool = false,
                reduceTransparency: Bool = false,
                increaseContrast: Bool = false) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }
}

public extension EnvironmentValues {
    @Entry var overtureTheme = Theme()
}

/// Resolves system accessibility settings into the theme once, near the root.
public struct ThemeResolver<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.environment(\.overtureTheme, Theme(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: NSWorkspace.shared
                .accessibilityDisplayShouldIncreaseContrast))
    }
}

/// Liquid Glass policy (§1.2): glass ONLY on floating chrome; never under
/// reading surfaces or the permission sheet. Under Reduce Transparency every
/// glass surface resolves to the opaque `surface.overlay`.
public struct GlassOrOpaque: ViewModifier {
    @Environment(\.overtureTheme) private var theme
    private let shape: AnyShape

    public init(in shape: some Shape) {
        self.shape = AnyShape(shape)
    }

    public func body(content: Content) -> some View {
        if theme.reduceTransparency {
            content.background(DS.Color.Surface.overlay, in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

public extension View {
    /// Floating-chrome background: Liquid Glass, or opaque overlay under
    /// Reduce Transparency. Content surfaces never use this.
    func glassOrOpaque(in shape: some Shape = .capsule) -> some View {
        modifier(GlassOrOpaque(in: shape))
    }

    /// The standard 2pt focus ring, offset 2pt (§7).
    func overtureFocusRing(_ focused: Bool, radius: CGFloat) -> some View {
        overlay {
            if focused {
                RoundedRectangle(cornerRadius: radius + 2)
                    .stroke(DS.Color.focusRing, lineWidth: 2)
                    .padding(-4)
            }
        }
    }
}
