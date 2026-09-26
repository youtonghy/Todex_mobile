import UIKit

enum Theme {
    static let onAccent = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.16, blue: 0.12, alpha: 1) : .white
    }
    static let accent = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.28, green: 0.77, blue: 0.62, alpha: 1)
            : UIColor(red: 0.05, green: 0.53, blue: 0.40, alpha: 1)
    }
    static let background = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.065, green: 0.105, blue: 0.135, alpha: 1)
            : UIColor(red: 0.959, green: 0.974, blue: 0.978, alpha: 1)
    }
    static let surface = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.16, blue: 0.19, alpha: 1) : .white
    }
    static let secondary = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.20, blue: 0.23, alpha: 1)
            : UIColor(red: 0.927, green: 0.946, blue: 0.950, alpha: 1)
    }
    static func icon(_ name: String, pointSize: CGFloat = 18) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }
    static func label(_ text: String, style: UIFont.TextStyle = .body, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
    static func button(_ title: String, icon: String? = nil, prominent: Bool = false, action: @escaping () -> Void)
        -> UIButton
    {
        var config = prominent ? UIButton.Configuration.filled() : .glass()
        config.title = title
        config.image = icon.flatMap { Self.icon($0) }
        config.imagePadding = 7
        config.cornerStyle = .capsule
        config.baseBackgroundColor = accent
        config.baseForegroundColor = prominent ? onAccent : accent
        config.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title
        return button
    }
    /// Selector chip matching the desktop `composer-control` style: subtle fill, leading icon,
    /// label, optional accent detail (e.g. `· high`) and a small trailing chevron.
    static func chipConfiguration(
        title: String, icon: String? = nil, detail: String? = nil, chevron: Bool = true
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = secondary
        config.baseForegroundColor = .label
        config.contentInsets = .init(top: 7, leading: 10, bottom: 7, trailing: 9)
        config.image = icon.flatMap { Self.icon($0, pointSize: 11) }
        config.imagePadding = 4
        config.titleLineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(
            string: title, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)])
        if let detail, !detail.isEmpty {
            text.append(
                NSAttributedString(
                    string: " \(detail)",
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .footnote),
                        .foregroundColor: accent,
                    ]))
        }
        if chevron, let mark = Self.icon("chevron.down", pointSize: 7) {
            text.append(NSAttributedString(string: " "))
            let attachment = NSTextAttachment(
                image: mark.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal))
            attachment.bounds = CGRect(
                x: 0, y: -1, width: mark.size.width, height: mark.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        config.attributedTitle = AttributedString(text)
        return config
    }
    static func chip(_ title: String, icon: String? = nil) -> UIButton {
        let button = UIButton(configuration: chipConfiguration(title: title, icon: icon))
        button.accessibilityLabel = title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return button
    }
    /// Icon-only capsule chip whose tint encodes the selected option
    /// (permission/work mode indicators in the composer toolbar).
    static func iconChipConfiguration(icon: String, tint: UIColor) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = secondary
        config.baseForegroundColor = tint
        config.image = Self.icon(icon, pointSize: 12)
        config.contentInsets = .init(top: 7, leading: 11, bottom: 7, trailing: 11)
        return config
    }
    /// Compact icon-only button matching the desktop ghost toolbar icons.
    static func iconButton(_ symbol: String, pointSize: CGFloat = 13) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = secondary
        config.baseForegroundColor = .label
        config.image = icon(symbol, pointSize: pointSize)
        config.contentInsets = .init(top: 7, leading: 9, bottom: 7, trailing: 9)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = symbol
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return button
    }
    static func applyAppearance(to window: UIWindow?) {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": window?.overrideUserInterfaceStyle = .light
        case "dark": window?.overrideUserInterfaceStyle = .dark
        default: window?.overrideUserInterfaceStyle = .unspecified
        }
        window?.tintColor = accent
    }
}

extension UIViewController {
    func showError(_ error: Error) { showNotice(title: String(localized: "无法完成操作"), message: error.localizedDescription) }
    func showNotice(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        WBUI.presentModal(alert, on: self)
    }
    func askText(
        title: String, message: String? = nil, value: String = "", placeholder: String = "",
        action: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value
            field.placeholder = placeholder
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "确定"), style: .default) { [weak alert] _ in
                guard let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return }
                action(text)
            })
        present(alert, animated: true)
    }
    func confirm(title: String, message: String, destructive: Bool = false, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "继续"), style: destructive ? .destructive : .default) { _ in action() })
        present(alert, animated: true)
    }
}

extension UIView {
    func pinEdges(to other: UIView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset),
        ])
    }
}
