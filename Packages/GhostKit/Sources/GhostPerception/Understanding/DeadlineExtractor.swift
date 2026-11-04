import Foundation

/// Extrait une échéance d'un texte en français ou en anglais.
///
/// Approche à règles explicites (pas d'apprentissage automatique). Les dates
/// relatives sont calculées par rapport à la date de l'e-mail.
///
/// Conventions horaires lorsque l'heure n'est pas précisée :
/// matin → 9 h, midi → 12 h, après-midi → 14 h, soir → 18 h, jour seul → 18 h.
public struct DeadlineExtractor: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Résultat détaillé : l'échéance et le fait qu'elle soit introduite par
    /// un marqueur explicite (« pour », « avant », « d'ici », « by »…).
    public struct Match: Sendable, Equatable {
        public var deadline: Deadline
        public var hasMarker: Bool
        public var location: Int
    }

    public func extract(from text: String, reference: Date) -> Deadline? {
        bestMatch(in: text, reference: reference)?.deadline
    }

    public func bestMatch(in text: String, reference: Date) -> Match? {
        let all = matches(in: text, reference: reference)
        return all.filter(\.hasMarker).min { $0.location < $1.location }
            ?? all.min { $0.location < $1.location }
    }

    // MARK: - Règles

    private static let marker = #"(?:\b(pour|d'ici(?:\s+à)?|avant|au plus tard|jusqu'à|jusqu'au|by|before|due|until|no later than)\s+(?:le\s+|la\s+|l'|ce\s+|cette\s+|the\s+)?)?"#
    private static let time = #"(?:\s+(?:(?:à|a|at|vers|avant|for|before)\s+)?(\d{1,2})\s*(?:h|:|heures?)(?:\s*(\d{2}))?(?![a-zà-ÿ]))?"#
    private static let partOfDay = #"(?:\s+(matin|midi|après-midi|apres-midi|aprem|soir|morning|afternoon|evening|night))?"#

    private static let relativeDay = Pattern(marker + #"\b(après-demain|apres-demain|après demain|demain|aujourd'hui|tomorrow|today|tonight|ce soir|cet après-midi|cet apres-midi|this afternoon|this evening)\b"# + partOfDay + time)
    private static let weekday = Pattern(marker + #"(?:next\s+)?\b(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b(?:\s+(?:prochain|next))?"# + partOfDay + time)
    private static let endOfDay = Pattern(marker + #"\b(fin de (?:la )?journée|fin de journee|end of (?:the )?day|eod|cob)\b"#)
    private static let endOfWeek = Pattern(marker + #"\b(fin de (?:la )?semaine|end of (?:the )?week)\b"#)
    private static let nextWeek = Pattern(marker + #"\b(semaine prochaine|next week)\b"#)
    private static let endOfMonth = Pattern(marker + #"\b(fin du mois|fin de mois|end of (?:the )?month)\b"#)
    private static let inDuration = Pattern(marker + #"\b(?:dans|in|sous|within)\s+(\d{1,3})\s+(jours?|heures?|semaines?|days?|hours?|weeks?)\b"#)
    private static let frenchDate = Pattern(marker + #"\b(\d{1,2})(?:er)?\s+(janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre)(?:\s+(\d{4}))?"# + time)
    private static let englishDate = Pattern(marker + #"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#)
    private static let numericDate = Pattern(marker + #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"# + time)
    private static let isoDate = Pattern(marker + #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    private static let timeOnly = Pattern(#"\b(avant|d'ici|pour|by|before)\s+(\d{1,2})\s*(h|:)\s*(\d{2})?"#)

    private static let frenchMonths = ["janvier": 1, "février": 2, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
                                       "juillet": 7, "août": 8, "aout": 8, "septembre": 9, "octobre": 10,
                                       "novembre": 11, "décembre": 12, "decembre": 12]
    private static let englishMonths = ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
                                        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12]
    /// Jours de la semaine au format de `Calendar` (1 = dimanche).
    private static let weekdays = ["dimanche": 1, "lundi": 2, "mardi": 3, "mercredi": 4, "jeudi": 5, "vendredi": 6, "samedi": 7,
                                   "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]

    func matches(in text: String, reference: Date) -> [Match] {
        var results: [Match] = []
        func add(_ match: Pattern.Match, _ resolved: (Date, Deadline.Precision)?) {
            guard let (date, precision) = resolved else { return }
            results.append(Match(deadline: Deadline(date: date, text: match.text.trimmingCharacters(in: .whitespaces),
                                                    precision: precision),
                                 hasMarker: match.groups[1] != nil, location: match.range.location))
        }

        for m in Self.relativeDay.matches(in: text) {
            let word = (m.groups[2] ?? "").lowercased()
            let offset: Int
            var defaultHour = 18
            var precision: Deadline.Precision = .day
            switch word {
            case "après-demain", "apres-demain", "après demain": offset = 2
            case "demain", "tomorrow": offset = 1
            case "ce soir", "tonight", "this evening": offset = 0; defaultHour = 19; precision = .partOfDay
            case "cet après-midi", "cet apres-midi", "this afternoon": offset = 0; defaultHour = 17; precision = .partOfDay
            default: offset = 0
            }
            guard let day = calendar.date(byAdding: .day, value: offset, to: reference) else { continue }
            add(m, at(day, part: m.groups[3], hour: m.groups[4], minute: m.groups[5],
                      defaultHour: defaultHour, defaultPrecision: precision))
        }
        for m in Self.weekday.matches(in: text) {
            guard let target = Self.weekdays[(m.groups[2] ?? "").lowercased()],
                  let day = nextWeekday(target, after: reference) else { continue }
            add(m, at(day, part: m.groups[3], hour: m.groups[4], minute: m.groups[5], defaultHour: 18, defaultPrecision: .day))
        }
        for m in Self.endOfDay.matches(in: text) {
            add(m, setTime(reference, hour: 18, minute: 0).map { ($0, .partOfDay) })
        }
        for m in Self.endOfWeek.matches(in: text) {
            let friday = calendar.component(.weekday, from: reference) == 6 ? reference : nextWeekday(6, after: reference)
            add(m, friday.flatMap { setTime($0, hour: 18, minute: 0) }.map { ($0, .week) })
        }
        for m in Self.nextWeek.matches(in: text) {
            let friday = nextWeekday(6, after: reference).flatMap { calendar.date(byAdding: .day, value: 7, to: $0) }
            add(m, friday.flatMap { setTime($0, hour: 18, minute: 0) }.map { ($0, .week) })
        }
        for m in Self.endOfMonth.matches(in: text) {
            guard let range = calendar.range(of: .day, in: .month, for: reference) else { continue }
            var components = calendar.dateComponents([.year, .month], from: reference)
            components.day = range.count
            components.hour = 18
            add(m, calendar.date(from: components).map { ($0, .month) })
        }
        for m in Self.inDuration.matches(in: text) {
            guard let amount = Int(m.groups[2] ?? "") else { continue }
            let unit = (m.groups[3] ?? "").lowercased()
            if unit.hasPrefix("heure") || unit.hasPrefix("hour") {
                add(m, calendar.date(byAdding: .hour, value: amount, to: reference).map { ($0, .exact) })
            } else {
                let days = unit.hasPrefix("semaine") || unit.hasPrefix("week") ? amount * 7 : amount
                add(m, calendar.date(byAdding: .day, value: days, to: reference)
                        .flatMap { setTime($0, hour: 18, minute: 0) }.map { ($0, .day) })
            }
        }
        for m in Self.frenchDate.matches(in: text) {
            guard let day = Int(m.groups[2] ?? ""), let month = Self.frenchMonths[(m.groups[3] ?? "").lowercased()] else { continue }
            add(m, calendarDate(day: day, month: month, year: m.groups[4].flatMap { Int($0) }, reference: reference,
                                hour: m.groups[5], minute: m.groups[6]))
        }
        for m in Self.englishDate.matches(in: text) {
            guard let month = Self.englishMonths[(m.groups[2] ?? "").lowercased()], let day = Int(m.groups[3] ?? "") else { continue }
            add(m, calendarDate(day: day, month: month, year: m.groups[4].flatMap { Int($0) }, reference: reference,
                                hour: nil, minute: nil))
        }
        for m in Self.numericDate.matches(in: text) {
            guard let day = Int(m.groups[2] ?? ""), let month = Int(m.groups[3] ?? ""), (1...12).contains(month) else { continue }
            var year = m.groups[4].flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            add(m, calendarDate(day: day, month: month, year: year, reference: reference, hour: m.groups[5], minute: m.groups[6]))
        }
        for m in Self.isoDate.matches(in: text) {
            guard let year = Int(m.groups[2] ?? ""), let month = Int(m.groups[3] ?? ""), let day = Int(m.groups[4] ?? "") else { continue }
            add(m, calendarDate(day: day, month: month, year: year, reference: reference, hour: nil, minute: nil))
        }
        // Heure seule introduite par un marqueur (« avant 17h ») — ignorée si
        // elle fait déjà partie d'une échéance plus complète.
        for m in Self.timeOnly.matches(in: text) where !results.contains(where: { NSIntersectionRange($0.range(in: text), m.range).length > 0 }) {
            guard let hour = Int(m.groups[2] ?? ""), hour < 24 else { continue }
            let minute = Int(m.groups[4] ?? "") ?? 0
            guard var date = setTime(reference, hour: hour, minute: minute) else { continue }
            if date <= reference, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
            results.append(Match(deadline: Deadline(date: date, text: m.text, precision: .exact), hasMarker: true,
                                 location: m.range.location))
        }
        return results
    }

    // MARK: - Calculs de dates

    private func at(_ day: Date, part: String?, hour: String?, minute: String?,
                    defaultHour: Int, defaultPrecision: Deadline.Precision) -> (Date, Deadline.Precision)? {
        if let hour = hour.flatMap({ Int($0) }), hour < 24 {
            return setTime(day, hour: hour, minute: minute.flatMap { Int($0) } ?? 0).map { ($0, .exact) }
        }
        switch part?.lowercased() {
        case "matin"?, "morning"?: return setTime(day, hour: 9, minute: 0).map { ($0, .partOfDay) }
        case "midi"?: return setTime(day, hour: 12, minute: 0).map { ($0, .partOfDay) }
        case "après-midi"?, "apres-midi"?, "aprem"?, "afternoon"?: return setTime(day, hour: 14, minute: 0).map { ($0, .partOfDay) }
        case "soir"?, "evening"?, "night"?: return setTime(day, hour: 18, minute: 0).map { ($0, .partOfDay) }
        default: return setTime(day, hour: defaultHour, minute: 0).map { ($0, defaultPrecision) }
        }
    }

    private func setTime(_ date: Date, hour: Int, minute: Int) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// Prochaine occurrence du jour `weekday`, strictement après le jour de `date`.
    private func nextWeekday(_ weekday: Int, after date: Date) -> Date? {
        let current = calendar.component(.weekday, from: date)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: date)
    }

    private func calendarDate(day: Int, month: Int, year: Int?, reference: Date,
                              hour: String?, minute: String?) -> (Date, Deadline.Precision)? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        var components = DateComponents()
        components.day = day
        components.month = month
        components.year = year ?? calendar.component(.year, from: reference)
        let explicitHour = hour.flatMap { Int($0) }.flatMap { $0 < 24 ? $0 : nil }
        components.hour = explicitHour ?? 18
        components.minute = minute.flatMap { Int($0) } ?? 0
        guard var date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil } // ex. 31/02
        // Sans année, une date passée désigne l'année suivante.
        if year == nil, date < calendar.startOfDay(for: reference),
           let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
        return (date, explicitHour == nil ? .day : .exact)
    }
}

private extension DeadlineExtractor.Match {
    func range(in text: String) -> NSRange {
        NSRange(location: location, length: (deadline.text as NSString).length)
    }
}
