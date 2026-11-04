import XCTest
@testable import GhostPerception

/// Exigence 3 (complément) : extraction d'échéances.
/// Référence : mercredi 4 novembre 2026, 10 h, Paris.
final class DeadlineExtractorTests: XCTestCase {
    private let extractor = DeadlineExtractor(calendar: parisCalendar)

    private func date(_ text: String) -> Date? { extractor.extract(from: text, reference: referenceDate)?.date }

    func testRelativeDays() {
        XCTAssertEqual(date("pour demain matin"), paris(2026, 11, 5, 9))
        XCTAssertEqual(date("demain à 10h30"), paris(2026, 11, 5, 10, 30))
        XCTAssertEqual(date("d'ici demain soir"), paris(2026, 11, 5, 18))
        XCTAssertEqual(date("pour après-demain"), paris(2026, 11, 6, 18))
        XCTAssertEqual(date("avant ce soir"), paris(2026, 11, 4, 19))
        XCTAssertEqual(date("by tomorrow morning"), paris(2026, 11, 5, 9))
    }

    func testWeekdays() {
        XCTAssertEqual(date("avant vendredi"), paris(2026, 11, 6, 18))
        XCTAssertEqual(date("jeudi à 14h"), paris(2026, 11, 5, 14))
        XCTAssertEqual(date("lundi 10h"), paris(2026, 11, 9, 10))
        XCTAssertEqual(date("mercredi prochain"), paris(2026, 11, 11, 18)) // même jour → semaine suivante
        XCTAssertEqual(date("by Friday"), paris(2026, 11, 6, 18))
    }

    func testCalendarDates() {
        XCTAssertEqual(date("le 15 novembre"), paris(2026, 11, 15, 18))
        XCTAssertEqual(date("pour le 2 janvier"), paris(2027, 1, 2, 18)) // passé → année suivante
        XCTAssertEqual(date("le 20/11 à 9h"), paris(2026, 11, 20, 9))
        XCTAssertEqual(date("due 2026-12-01"), paris(2026, 12, 1, 18))
        XCTAssertEqual(date("before December 3rd"), paris(2026, 12, 3, 18))
        XCTAssertNil(date("le 31/02"))
    }

    func testPeriods() {
        XCTAssertEqual(date("d'ici la fin de la semaine"), paris(2026, 11, 6, 18))
        XCTAssertEqual(date("pour la fin du mois"), paris(2026, 11, 30, 18))
        XCTAssertEqual(date("la semaine prochaine"), paris(2026, 11, 13, 18))
        XCTAssertEqual(date("dans 3 jours"), paris(2026, 11, 7, 18))
        XCTAssertEqual(date("avant 17h"), paris(2026, 11, 4, 17))
        XCTAssertEqual(date("avant 9h"), paris(2026, 11, 5, 9)) // déjà passé → lendemain
    }

    func testMarkedDeadlineIsPreferred() {
        let match = extractor.bestMatch(in: "Suite à la réunion de lundi, envoie-moi le rapport avant jeudi.",
                                        reference: referenceDate)
        XCTAssertEqual(match?.deadline.text, "avant jeudi")
        XCTAssertEqual(match?.hasMarker, true)
    }

    func testNoDeadline() {
        XCTAssertNil(date("Merci pour ton aide, à bientôt."))
        XCTAssertNil(date("Nous étions 10 hommes sur le terrain."))
    }
}
