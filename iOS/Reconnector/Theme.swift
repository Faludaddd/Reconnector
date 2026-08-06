import SwiftUI

// MARK: - Design System
// Shared tokens so every screen looks the same.

enum AppTheme {
    static let cornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 18
    static let innerSpacing: CGFloat = 12
    static let horizontalInset: CGFloat = 18

    static let cardBackground = Color(UIColor.secondarySystemBackground)
    static let subtleBackground = Color(UIColor.tertiarySystemBackground)

    static let titleFont = Font.system(.headline, design: .default).weight(.semibold)
    static let bodyFont = Font.system(.subheadline)
    static let captionFont = Font.system(.caption)
    static let monoFont = Font.system(.caption, design: .monospaced)
}

// MARK: - AppCard
// One unified card style used everywhere.

struct AppCard<Content: View>: View {
    let title: String?
    let icon: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.innerSpacing) {
            if let title = title {
                HStack(spacing: 8) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    Text(title)
                        .font(AppTheme.titleFont)
                }
            }
            content
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }
}

// MARK: - AppButton
// Shared button styles for primary / secondary / destructive actions.

enum AppButtonStyle {
    case primary
    case secondary
    case destructive
}

struct AppActionButton: View {
    let title: String
    let icon: String
    let style: AppButtonStyle
    let disabled: Bool
    let action: () -> Void

    init(_ title: String, icon: String, style: AppButtonStyle = .secondary, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(style == .destructive ? .red : .accentColor)
        .disabled(disabled)
    }
}

// MARK: - AppToggleRow
// Unified toggle row used inside cards.

struct AppToggleRow: View {
    let title: String
    let icon: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundColor(.accentColor)
            }
            Text(title)
                .font(AppTheme.bodyFont)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AppInfoRow
// Unified "label : value" row used in dashboard, monitoring, settings.

struct AppInfoRow: View {
    let label: String
    let value: String
    let color: Color

    init(_ label: String, _ value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(AppTheme.bodyFont)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .fontWeight(.medium)
                .font(AppTheme.bodyFont)
        }
    }
}
