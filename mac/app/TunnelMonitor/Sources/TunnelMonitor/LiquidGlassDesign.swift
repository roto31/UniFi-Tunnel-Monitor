import SwiftUI

/// Liquid Glass styling (macOS 26+) with material fallbacks for macOS 14–25.
enum LiquidGlassDesign {
    static let sectionCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 12
    static let containerSpacing: CGFloat = 14
}

// MARK: - Window / popover chrome

private struct TMAppWindowBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.06),
                            Color.clear,
                            Color.blue.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Section cards (text sits on card content, glass behind)

private struct TMGlassCardModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(LiquidGlassDesign.cardPadding)
                .glassEffect(glassMaterial(tint: tint), in: glassShape)
        } else {
            content
                .padding(LiquidGlassDesign.cardPadding)
                .background(fallbackMaterial, in: glassShape)
        }
    }

    @available(macOS 26.0, *)
    private func glassMaterial(tint: Color?) -> Glass {
        if let tint {
            return .regular.tint(tint.opacity(0.35))
        }
        return .regular
    }

    private var glassShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LiquidGlassDesign.sectionCornerRadius, style: .continuous)
    }

    private var fallbackMaterial: some ShapeStyle {
        if let tint {
            return AnyShapeStyle(tint.opacity(0.08))
        }
        return AnyShapeStyle(.regularMaterial)
    }
}

// MARK: - Status badge (compact glass capsule)

private struct TMGlassBadgeModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.tint(tint.opacity(0.45)), in: .capsule)
        } else {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.18), in: Capsule())
        }
    }
}

// MARK: - Section container (merging glass shapes on macOS 26)

struct TMSectionContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: LiquidGlassDesign.containerSpacing) {
                content()
            }
        } else {
            VStack(alignment: .leading, spacing: LiquidGlassDesign.containerSpacing) {
                content()
            }
        }
    }
}

// MARK: - View extensions

extension View {
    func tmAppWindowBackground() -> some View {
        modifier(TMAppWindowBackgroundModifier())
    }

    func tmGlassCard(tint: Color? = nil) -> some View {
        modifier(TMGlassCardModifier(tint: tint))
    }

    func tmGlassBadge(tint: Color) -> some View {
        modifier(TMGlassBadgeModifier(tint: tint))
    }

    @ViewBuilder
    func tmGlassActionButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func tmGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// macOS 26 unified toolbar on dashboard (View-level; SceneBuilder cannot branch on OS).
struct TMUnifiedToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

