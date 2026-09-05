import SwiftUI

enum ExecuteSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum ExecuteRadius {
    // Large radii make primary surfaces feel composed and tactile instead of boxed in.
    static let small: CGFloat = 12
    static let card: CGFloat = 22
    static let compact: CGFloat = 16
    static let pill: CGFloat = 999
}

enum ExecuteShadow {
    static let card = (color: ExecuteColor.charcoal.opacity(0.085), radius: CGFloat(16), y: CGFloat(5))
    static let raised = (color: ExecuteColor.charcoal.opacity(0.12), radius: CGFloat(26), y: CGFloat(8))
    static let lime = (color: ExecuteColor.chartreuse.opacity(0.32), radius: CGFloat(20), y: CGFloat(5))
}

enum ExecuteHomeStyle {
    static let screenInset: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let relatedGap: CGFloat = 8
    static let bottomContentInset: CGFloat = 56
    static let heroRadius: CGFloat = 28
    static let cardRadius: CGFloat = 22
    static let utilityRadius: CGFloat = 16
    static let heroShadow = (color: ExecuteColor.charcoal.opacity(0.075), radius: CGFloat(16), y: CGFloat(5))
    static let utilityShadow = (color: ExecuteColor.charcoal.opacity(0.045), radius: CGFloat(8), y: CGFloat(2))
    static let planWash = ExecuteColor.chartreuse.opacity(0.09)
    static let actionWash = ExecuteColor.chartreuse.opacity(0.72)
    static let accentWash = ExecuteColor.chartreuse.opacity(0.11)
    static let positiveWash = ExecuteColor.chartreuse.opacity(0.06)
    static let accentBorder = ExecuteColor.chartreuseDark.opacity(0.18)
    static let actionBorder = ExecuteColor.chartreuseDark.opacity(0.22)
}

enum ExecuteMotion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.2)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let gentleSpring = Animation.spring(response: 0.5, dampingFraction: 0.82)
}

enum ExecuteTypography {
    // Use the bundled PostScript names so SwiftUI does not silently fall back to SF Pro.
    static func display(_ size: CGFloat) -> Font { .custom("Inter-Black", size: size) }
    static func title(_ size: CGFloat = 22) -> Font { .custom("Inter-SemiBold", size: size) }
    static func body(_ size: CGFloat = 16) -> Font { .custom("Inter-Regular", size: size) }
    static func label(_ size: CGFloat = 13) -> Font { .custom("Inter-Medium", size: size) }
    static func caption(_ size: CGFloat = 11) -> Font { .custom("Inter-Medium", size: size) }
}

struct ExecuteScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(ExecuteColor.charcoal)
            .background(ExecuteColor.parchment.ignoresSafeArea())
    }
}

extension View {
    func executeScreen() -> some View { modifier(ExecuteScreen()) }
}
