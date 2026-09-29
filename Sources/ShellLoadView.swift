import UIKit

// Alles wat de app zelf over de webview tekent tijdens het laden, in één weergave:
// - een startscherm (het icoon en een spinner) tot de eerste pin is getekend
// - een dun voortgangsbalkje bovenaan tijdens elke lading
// - een "geen verbinding"-scherm met een knop om het opnieuw te proberen
// - een kort melding-bolletje als een lading mislukt terwijl er al een pagina staat
// De Coordinator in ContentView.swift bepaalt wat er getoond wordt (één plek, dus geen concurrerende
// overlays). De weergave laat aanrakingen door, behalve waar het startscherm of de foutmelding staat.
@MainActor
final class ShellLoadView: UIView {
    var onRetry: (() -> Void)?

    // Kleuren van het app-icoon
    private static let teal = UIColor(red: 0.09, green: 0.71, blue: 0.64, alpha: 1)
    private static let blue = UIColor(red: 0.15, green: 0.26, blue: 0.66, alpha: 1)

    private let placeholder = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bar = UIProgressView(progressViewStyle: .bar)
    private let failure = UIView()
    private let failureTitle = UILabel()
    private let failureMessage = UILabel()
    private let toastLabel = ShellToastLabel()
    private var barToken = 0
    private var toastToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildPlaceholder()
        buildFailure()

        bar.progressTintColor = Self.teal
        bar.trackTintColor = .clear
        bar.alpha = 0
        bar.isUserInteractionEnabled = false
        addSubview(bar)

        toastLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.88)
        toastLabel.layer.cornerRadius = 15
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        addSubview(toastLabel)
    }

    required init?(coder: NSCoder) { fatalError("niet gebruikt") }

    // Alleen aanraken opvangen waar we echt iets tonen; de rest gaat naar de webview
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 3)
        let size = toastLabel.intrinsicContentSize
        toastLabel.frame = CGRect(x: (bounds.width - size.width) / 2, y: 14, width: size.width, height: size.height)
    }

    // MARK: Startscherm

    private func buildPlaceholder() {
        placeholder.frame = bounds
        placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        placeholder.backgroundColor = .systemBackground
        addSubview(placeholder)

        // Het icoon nagetekend: verloop van turkoois naar blauw met een witte punaise
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer.cornerRadius = 24
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        let gradient = CAGradientLayer()
        gradient.colors = [Self.teal.cgColor, Self.blue.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 104, height: 104)
        tile.layer.addSublayer(gradient)
        let pin = UIImageView(image: UIImage(systemName: "pin.fill",
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 46, weight: .semibold)))
        pin.tintColor = .white
        pin.contentMode = .center
        pin.frame = CGRect(x: 0, y: 0, width: 104, height: 104)
        tile.addSubview(pin)
        placeholder.addSubview(tile)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .secondaryLabel
        spinner.startAnimating()
        placeholder.addSubview(spinner)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 104),
            tile.heightAnchor.constraint(equalToConstant: 104),
            tile.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor, constant: -24),
            spinner.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 30),
        ])
    }

    func showPlaceholder() {
        placeholder.layer.removeAllAnimations()
        placeholder.isHidden = false
        placeholder.alpha = 1
        spinner.startAnimating()
    }

    func hidePlaceholder() {
        guard !placeholder.isHidden else { return }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
            self.placeholder.alpha = 0
        } completion: { finished in
            guard finished else { return }
            self.placeholder.isHidden = true
            self.spinner.stopAnimating()
        }
    }

    // MARK: Voortgang

    func updateProgress(_ progress: Double, loading: Bool) {
        barToken += 1
        if loading {
            bar.layer.removeAllAnimations()
            bar.alpha = 1
            let value = Float(min(max(progress, 0.08), 0.95))
            bar.setProgress(value, animated: value > bar.progress)
        } else {
            let token = barToken
            bar.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.3, delay: 0.25, options: []) {
                self.bar.alpha = 0
            } completion: { _ in
                if token == self.barToken { self.bar.setProgress(0, animated: false) }
            }
        }
    }

    // MARK: Foutmelding

    private func buildFailure() {
        failure.frame = bounds
        failure.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        failure.backgroundColor = .systemBackground
        failure.isHidden = true
        addSubview(failure)

        let icon = UIImageView(image: UIImage(systemName: "wifi.slash",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
        icon.tintColor = .tertiaryLabel
        failureTitle.font = .systemFont(ofSize: 22, weight: .bold)
        failureTitle.textColor = .label
        failureTitle.textAlignment = .center
        failureMessage.font = .systemFont(ofSize: 16)
        failureMessage.textColor = .secondaryLabel
        failureMessage.textAlignment = .center
        failureMessage.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = "Probeer opnieuw"
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Self.teal
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 26, bottom: 12, trailing: 26)
        let retry = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onRetry?() })

        let stack = UIStackView(arrangedSubviews: [icon, failureTitle, failureMessage, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(24, after: failureMessage)
        stack.translatesAutoresizingMaskIntoConstraints = false
        failure.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: failure.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: failure.centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: failure.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: failure.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    func showFailure(title: String, message: String) {
        failureTitle.text = title
        failureMessage.text = message
        failure.isHidden = false
        placeholder.layer.removeAllAnimations()
        placeholder.isHidden = true
        spinner.stopAnimating()
    }

    func hideFailure() {
        failure.isHidden = true
    }

    // MARK: Melding

    func toast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toastLabel.text = text
        toastLabel.invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard token == self.toastToken else { return }
            UIView.animate(withDuration: 0.3) { self.toastLabel.alpha = 0 }
        }
    }
}

// Label met ruimte rondom de tekst
private final class ShellToastLabel: UILabel {
    private let inset = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}
