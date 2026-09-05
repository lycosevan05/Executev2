import SwiftUI

struct ExecutePrimaryButton: View {
    let title: String
    let action: () -> Void
    var isLoading = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading { ProgressView().tint(ExecuteColor.charcoal) }
                else { Text(title).font(ExecuteTypography.label(15)) }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(ExecuteFilledButtonStyle())
        .disabled(isLoading)
    }
}

struct ExecuteSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(ExecuteTypography.label(15))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(ExecuteColor.parchmentLight)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous).stroke(ExecuteColor.warmBorder))
            .buttonStyle(ExecutePressStyle())
    }
}

struct ExecuteIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(ExecuteColor.parchmentLight)
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
        .buttonStyle(ExecutePressStyle())
    }
}

struct ExecuteFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ExecuteColor.charcoal)
            .background(ExecuteColor.chartreuse)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
            .shadow(color: ExecuteShadow.lime.color, radius: ExecuteShadow.lime.radius, y: ExecuteShadow.lime.y)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(ExecuteMotion.quick, value: configuration.isPressed)
    }
}

struct ExecutePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(ExecuteMotion.quick, value: configuration.isPressed)
    }
}

struct ExecuteCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(ExecuteColor.parchmentLight)
            .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ExecuteRadius.card, style: .continuous).stroke(ExecuteColor.warmBorder.opacity(0.58), lineWidth: 0.8))
            .shadow(color: ExecuteShadow.card.color, radius: ExecuteShadow.card.radius, y: ExecuteShadow.card.y)
    }
}

struct ExecuteStatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        ExecuteCard {
            HStack(alignment: .top, spacing: ExecuteSpacing.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    .frame(width: 26, height: 26)
                    .background(ExecuteColor.chartreuse.opacity(0.2))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: ExecuteSpacing.xxs) {
                    Text(title).font(ExecuteTypography.caption()).foregroundStyle(ExecuteColor.olive)
                    Text(value).font(ExecuteTypography.title(20))
                }
                Spacer()
            }
            .padding(ExecuteSpacing.md)
        }
    }
}

struct ExecuteSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(ExecuteTypography.title(20))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(ExecuteTypography.label())
                    .foregroundStyle(ExecuteColor.chartreuseDark)
            }
        }
    }
}

struct ExecuteBadge: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(ExecuteTypography.caption(10))
            .foregroundStyle(ExecuteColor.charcoal)
            .padding(.horizontal, ExecuteSpacing.xs)
            .padding(.vertical, ExecuteSpacing.xxs)
            .background(ExecuteColor.chartreuse)
            .clipShape(Capsule())
    }
}

struct ExecuteSkeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous)
            .fill(ExecuteColor.warmBorder.opacity(0.75))
            .overlay(
                LinearGradient(
                    colors: [.clear, ExecuteColor.chartreuse.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .redacted(reason: .placeholder)
    }
}

struct ExecuteEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(ExecuteColor.chartreuseDark)
            Text(title).font(ExecuteTypography.title(18))
            Text(message).font(ExecuteTypography.body(14)).foregroundStyle(ExecuteColor.olive).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(ExecuteSpacing.xl)
    }
}

struct ExecuteErrorState: View {
    let error: AppError
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: ExecuteSpacing.sm) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(ExecuteColor.destructive)
            Text(error.title).font(ExecuteTypography.title(18))
            Text(error.message).font(ExecuteTypography.body(14)).foregroundStyle(ExecuteColor.olive).multilineTextAlignment(.center)
            if let retry { ExecuteSecondaryButton(title: "Try again", action: retry) }
        }
        .padding(ExecuteSpacing.xl)
    }
}

struct ExecuteDivider: View {
    var body: some View { Rectangle().fill(ExecuteColor.warmBorder).frame(height: 1) }
}

struct ExecuteProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(ExecuteColor.warmBorder, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(ExecuteColor.chartreuse, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1.5), value: progress)
        }
    }
}
