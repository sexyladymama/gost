import AppKit
import SwiftUI

/// Direction artistique de GHOST : noir profond (ou blanc cassé en mode clair),
/// verre liquide, typographie de terminal. Sobre et technique — une seule
/// teinte d'accent, pas de dégradés criards ni d'effets « IA ».
enum GhostTheme {
    /// Couleur qui change avec l'apparence de la vue (clair / sombre).
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let backgroundNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.027, green: 0.031, blue: 0.039, alpha: 1)
            : NSColor(red: 0.953, green: 0.959, blue: 0.969, alpha: 1)
    }

    static let background = Color(nsColor: backgroundNS)
    static let ink = adaptive(dark: NSColor(white: 0.94, alpha: 1), light: NSColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))
    static let dim = adaptive(dark: NSColor(white: 0.94, alpha: 0.55), light: NSColor(white: 0.1, alpha: 0.55))
    /// Bleu : seul accent de l'interface (glacier en sombre, plus profond en clair).
    static let accent = adaptive(dark: NSColor(red: 0.56, green: 0.78, blue: 1.0, alpha: 1),
                                 light: NSColor(red: 0.10, green: 0.38, blue: 0.85, alpha: 1))
    static let teal = adaptive(dark: NSColor(red: 0.16, green: 0.78, blue: 0.70, alpha: 1),
                               light: NSColor(red: 0.0, green: 0.60, blue: 0.55, alpha: 1))
    /// Texte posé sur une surface d'accent pleine.
    static let onAccent = adaptive(dark: NSColor(red: 0.027, green: 0.031, blue: 0.039, alpha: 1), light: .white)
    /// Dessous des cartes en verre : garde le verre lisible quoi qu'il y ait derrière.
    static let glassUnderlay = adaptive(dark: NSColor(white: 0, alpha: 0.42), light: NSColor(white: 1, alpha: 0.55))
    static let dots = adaptive(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.08))
}

// MARK: - Mode clair / sombre

/// Choix de l'utilisateur, mémorisé entre les lancements.
enum GhostAppearance: String {
    case dark, light
    static let storageKey = "ghost.appearance"

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var toggled: GhostAppearance { self == .dark ? .light : .dark }
    var symbol: String { self == .dark ? "sun.max" : "moon" }
    var toggleHelp: String { self == .dark ? "Passer en mode clair" : "Passer en mode sombre" }
    var nsAppearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

/// Petit bouton rond en verre : soleil en mode sombre, lune en mode clair.
struct GhostAppearanceToggle: View {
    @AppStorage(GhostAppearance.storageKey) private var raw = GhostAppearance.dark.rawValue
    private var current: GhostAppearance { GhostAppearance(rawValue: raw) ?? .dark }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { raw = current.toggled.rawValue }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GhostTheme.ink)
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
                .ghostGlass(cornerRadius: 15)
        }
        .buttonStyle(.plain)
        .help(current.toggleHelp)
        .accessibilityLabel(current.toggleHelp)
    }
}

extension View {
    /// Applique le mode clair / sombre choisi, la couleur d'accent et la couleur de texte.
    func ghostAppearance(_ appearance: GhostAppearance) -> some View {
        self
            .environment(\.colorScheme, appearance.colorScheme)
            .preferredColorScheme(appearance.colorScheme)
            .foregroundStyle(GhostTheme.ink)
            .tint(GhostTheme.accent)
    }
}

// MARK: - Fond

/// Fond avec deux lueurs froides très discrètes (de quoi donner de la matière
/// au verre) et une grille de points fine.
struct GhostBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let glow = scheme == .dark ? 1.0 : 0.55
        ZStack {
            GhostTheme.background
            RadialGradient(colors: [GhostTheme.accent.opacity(0.20 * glow), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [GhostTheme.teal.opacity(0.13 * glow), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 520)
            Canvas { context, size in
                let step: CGFloat = 22
                var path = Path()
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                        x += step
                    }
                    y += step
                }
                context.fill(path, with: .color(GhostTheme.dots))
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Verre liquide

/// Surface en verre : effet « Liquid Glass » natif sur macOS 26, matériau
/// translucide avec reflet et liseré en dessous.
struct GhostGlass: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(GhostTheme.glassUnderlay, in: shape)
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular, in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
        } else {
            content
                .background(GhostTheme.glassUnderlay, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .white).opacity(0.04), in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
        }
    }

    /// Liseré lumineux : plus clair en haut à gauche, comme un reflet.
    private var rim: LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.05), .white.opacity(0.14)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.04), .black.opacity(0.12)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    func ghostGlass(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GhostGlass(cornerRadius: cornerRadius, tint: tint))
    }
}

/// Bouton en verre. `prominent` le teinte de l'accent.
struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : (prominent ? GhostTheme.onAccent : GhostTheme.ink))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if prominent && !destructive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GhostTheme.accent.opacity(0.92))
                }
            }
            .ghostGlass(cornerRadius: 12, tint: destructive ? .red : nil)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Texte qui se tape

/// Texte qui s'écrit lettre par lettre, comme sur un clavier : rythme
/// légèrement irrégulier, curseur bloc qui clignote une fois la frappe finie.
/// Avec « Réduire les animations », le texte s'affiche directement.
struct TypewriterText: View {
    let text: String
    var size: CGFloat = 22
    var weight: Font.Weight = .medium
    var color: Color = GhostTheme.ink
    var startDelay: Double = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var typing = true

    var body: some View {
        ZStack(alignment: .leading) {
            // Réserve la largeur finale : rien ne bouge pendant la frappe.
            Text(text).font(font).tracking(size * 0.08).opacity(0)
            HStack(spacing: 2) {
                Text(String(text.prefix(shown))).font(font).tracking(size * 0.08).foregroundStyle(color)
                cursor
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .task {
            if reduceMotion { shown = text.count; typing = false; return }
            shown = 0; typing = true
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            for index in 1...max(text.count, 1) {
                guard !Task.isCancelled else { return }
                shown = index
                // Rythme de frappe : base + variation déterministe.
                let jitter = Double((index * 7919) % 11) / 11.0
                try? await Task.sleep(nanoseconds: UInt64((0.085 + jitter * 0.12) * 1_000_000_000))
            }
            typing = false
        }
    }

    private var font: Font { .system(size: size, weight: weight, design: .monospaced) }

    private var cursor: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle()
                .fill(GhostTheme.accent)
                .frame(width: size * 0.5, height: size * 0.95)
                .opacity(typing || phase ? 1 : 0)
                .shadow(color: GhostTheme.accent.opacity(0.6), radius: 6)
        }
    }
}

/// Signature de l'application : nom tapé + ligne de sous-titre.
struct GhostWordmark: View {
    var size: CGFloat = 22
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TypewriterText(text: "GHOST", size: size)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: max(10, size * 0.45), design: .monospaced))
                    .foregroundStyle(GhostTheme.dim)
            }
        }
    }
}
