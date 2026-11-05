import XCTest
import GhostPerception
@testable import GhostVision

final class PrivacyFilterTests: XCTestCase {
    let policy = PrivacyPolicy()

    func testAIAssistantsAreNotReadBecauseTheirAnswersAddressTheUser() {
        for app in ["Claude", "Codex", "ChatGPT"] {
            XCTAssertEqual(policy.decide(ScreenContext(app: app)), .skip("application exclue"), app)
        }
        XCTAssertEqual(policy.decide(ScreenContext(app: "Messages")), .allow)
    }

    func testPasswordManagersBanksAndPrivateWindowsAreSkippedBeforeAnyReading() {
        XCTAssertEqual(policy.decide(ScreenContext(app: "1Password", bundleID: "com.1password.1password")), .skip("application exclue"))
        XCTAssertEqual(policy.decide(ScreenContext(app: "Trousseau d'accès", bundleID: "com.apple.keychainaccess")), .skip("application exclue"))
        XCTAssertNotEqual(policy.decide(ScreenContext(app: "Bitwarden", bundleID: nil)), .allow)
        XCTAssertEqual(policy.decide(ScreenContext(app: "Safari", windowTitle: "Navigation privée — Accueil")), .skip("navigation privée"))
        XCTAssertNotEqual(policy.decide(ScreenContext(app: "Google Chrome", windowTitle: "Nouvel onglet incognito")), .allow)
        XCTAssertNotEqual(policy.decide(ScreenContext(app: "Safari", windowTitle: "Mon compte — Boursorama Banque")), .allow)
        XCTAssertNotEqual(policy.decide(ScreenContext(app: "Safari", windowTitle: "PayPal : connexion")), .allow)
        XCTAssertNotEqual(policy.decide(ScreenContext(app: "Terminal", bundleID: "app.ghost.shell")), .allow, "GHOST ne lit jamais sa propre fenêtre")
        XCTAssertEqual(policy.decide(ScreenContext(app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", windowTitle: "Marie")), .allow)
        XCTAssertEqual(policy.decide(ScreenContext(app: "Ghostty", bundleID: "com.mitchellh.ghostty", windowTitle: "zsh")), .allow, "« ghost » dans un nom n'exclut pas une autre app")
        XCTAssertNotEqual(PrivacyPolicy(extraExcludedApps: ["Notes perso"]).decide(ScreenContext(app: "Notes perso")), .allow)
    }

    func testSensitiveBlocksAreDroppedAndSecretsMasked() {
        XCTAssertNil(policy.sanitize("Votre code de vérification est 482913"))
        XCTAssertNil(policy.sanitize("CVV : 123"))
        XCTAssertNil(policy.sanitize("Mot de passe : hunter2"))
        XCTAssertNil(policy.sanitize("IBAN FR76 3000 6000 0112 3456 7890 189"))
        XCTAssertNil(policy.sanitize("BIC : AGRIFRPP"), "« bic » entier")
        XCTAssertNotNil(policy.sanitize("Une réunion publique a lieu jeudi à 18h"), "« public » ne contient pas « bic »")
        XCTAssertEqual(PrivacyPolicy.redact("Carte 4111 1111 1111 1111 expire 12/28"), "Carte [carte] expire 12/28")
        XCTAssertEqual(PrivacyPolicy.redact("Commande 1234 5678 9012 3456"), "Commande 1234 5678 9012 3456", "pas un numéro de carte valide (Luhn)")
        XCTAssertFalse(PrivacyPolicy.redact("clé sk-abcdefghijklmnop12345678").contains("sk-abc"))
        XCTAssertFalse(PrivacyPolicy.redact("token ghp_abcdefghijklmnopqrstuvwx").contains("ghp_abc"))
        XCTAssertTrue(PrivacyPolicy.redact("rdv jeudi à 14h avec Marie").contains("jeudi à 14h"), "le texte utile est conservé")
    }

    func testBlocksAreGroupedByProximityAndAlignment() {
        func line(_ t: String, y: CGFloat, x: CGFloat = 0.1) -> RecognizedLine { RecognizedLine(text: t, box: CGRect(x: x, y: y, width: 0.5, height: 0.03)) }
        let blocks = TextBlocks.group([
            line("Marie : peux-tu me préparer", y: 0.90), line("un fichier Excel pour demain ?", y: 0.865),
            line("Paul : ok je regarde ça", y: 0.60),
            RecognizedLine(text: "x", box: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.03)),
            RecognizedLine(text: "texte flou illisible", box: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.03), confidence: 0.1)
        ])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.lineCount, 2)
        XCTAssertTrue(blocks.first?.text.contains("fichier Excel") ?? false)
    }
}

final class AppointmentExtractorTests: XCTestCase {
    let extractor = AppointmentExtractor(calendar: visionCalendar)
    func drafts(_ text: String) -> [AppointmentDraft] { extractor.drafts(in: text, reference: visionNow) }

    func testDinnerWithExplicitDateAndTimeIsCertain() throws {
        let d = try XCTUnwrap(drafts("On a un dîner le 10 novembre à 21h").first)
        XCTAssertEqual(d.title, "Dîner")
        XCTAssertEqual(d.start, parisAt(2026, 11, 10, 21))
        XCTAssertEqual(d.end, parisAt(2026, 11, 10, 23))
        XCTAssertTrue(d.hasExplicitTime); XCTAssertTrue(d.certain)
    }
    func testPersonPlaceAndWeekday() throws {
        let d = try XCTUnwrap(drafts("Dîner avec Marie jeudi à 20h30 chez Paul").first)
        XCTAssertEqual(d.title, "Dîner avec Marie"); XCTAssertEqual(d.location, "chez Paul")
        XCTAssertEqual(d.start, parisAt(2026, 11, 5, 20, 30)); XCTAssertTrue(d.certain)
        XCTAssertEqual(try XCTUnwrap(drafts("Meeting on Friday at 14:30").first).start, parisAt(2026, 11, 6, 14, 30))
        XCTAssertEqual(try XCTUnwrap(drafts("RDV demain à 9h avec le dentiste").first).start, parisAt(2026, 11, 5, 9))
    }
    func testUncertainFormulationsAreNeverCertain() throws {
        XCTAssertFalse(try XCTUnwrap(drafts("Dîner le 10 novembre à 21h ?").first).certain, "question")
        XCTAssertFalse(try XCTUnwrap(drafts("Peut-être un dîner jeudi à 21h").first).certain, "hypothèse")
        let noTime = try XCTUnwrap(drafts("Dîner le 10 novembre").first)
        XCTAssertFalse(noTime.hasExplicitTime); XCTAssertFalse(noTime.certain, "sans heure : jamais d'ajout automatique")
    }
    func testNonAppointmentsAreIgnored() {
        XCTAssertTrue(drafts("Rendez-vous avant vendredi").isEmpty, "une échéance n'est pas un rendez-vous")
        XCTAssertTrue(drafts("Réunion annulée jeudi à 14h").isEmpty, "annulation")
        XCTAssertTrue(drafts("Soirée -20% profitez de l'offre jeudi à 20h").isEmpty, "promotion")
        XCTAssertTrue(drafts("Inscrivez-vous au webinaire jeudi à 18h").isEmpty)
        XCTAssertTrue(drafts("Il fait beau le 10 novembre à 21h").isEmpty, "pas d'événement nommé")
        XCTAssertTrue(drafts("Dîner").isEmpty)
    }
}

final class RealOCRTests: XCTestCase {
    func testVisionReadsRenderedTextLocally() async throws {
        let image = renderScreen(["Marie : On a un dîner le 10 novembre à 21h", "Peux-tu me préparer un fichier Excel pour demain matin ?"])
        let lines = try await VisionTextRecognizer().recognize(image)
        let text = lines.map(\.text).joined(separator: "\n")
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        XCTAssertTrue(folded.contains("diner"), text)
        XCTAssertTrue(folded.contains("novembre"), text)
        XCTAssertTrue(folded.contains("excel"), text)
        XCTAssertTrue(lines.allSatisfy { $0.box.height > 0 && $0.box.maxY <= 1.01 })
        // Le texte lu alimente directement l'extracteur de rendez-vous.
        let drafts = AppointmentExtractor(calendar: visionCalendar).drafts(in: text, reference: visionNow)
        XCTAssertEqual(drafts.first?.start, parisAt(2026, 11, 10, 21), text)
    }
}

final class RealCaptureGuardTests: XCTestCase {
    /// La vraie capture (ScreenCaptureKit) ne demande jamais la permission et ne capture rien sans elle.
    func testRealFrameSourceCapturesNothingWithoutMacOSPermission() async throws {
        try XCTSkipIf(ScreenCaptureKitFrameSource.hasPermission, "Cette machine a déjà accordé l'enregistrement de l'écran au processus de test.")
        let frame = try await ScreenCaptureKitFrameSource().capture()
        XCTAssertNil(frame, "sans permission macOS : aucune capture, aucune erreur, aucune invite")
    }
}
