import Foundation

/// Recherche en langage courant (« demain 9h au boulot »), avant résolution des lieux.
public struct ParsedQuery: Hashable, Sendable {
    public enum PlaceTerm: Hashable, Sendable {
        case currentLocation
        case home
        case work
        /// Nom tel qu'écrit (sans accents), à chercher parmi les arrêts puis dans Plans.
        case named(String)
    }

    public var origin: PlaceTerm?
    public var destination: PlaceTerm?
    /// `nil` : aucune indication d'heure.
    public var time: TimeConstraint?
    /// Heure déduite d'un moment vague (« demain », « ce soir ») plutôt que donnée.
    public var isTimeApproximate = false
    public var preference: RoutingOptions.Preference?
    /// Mots non compris.
    public var leftover = ""

    public init(origin: PlaceTerm? = nil, destination: PlaceTerm? = nil, time: TimeConstraint? = nil, isTimeApproximate: Bool = false, preference: RoutingOptions.Preference? = nil, leftover: String = "") {
        self.origin = origin
        self.destination = destination
        self.time = time
        self.isTimeApproximate = isTimeApproximate
        self.preference = preference
        self.leftover = leftover
    }

    /// Tout a été compris et il y a une destination.
    public var isConfident: Bool { destination != nil && leftover.isEmpty }
}

/// Analyse déterministe des recherches en français (heures, jours, lieux, préférences).
public enum QueryParser {
    public static func parse(_ text: String, now: Date = Date()) -> ParsedQuery {
        var s = Scanner(normalize(text))
        var query = ParsedQuery()

        // Préférences.
        if s.take(#"\b(?:sans (?:aucune )?correspondances?|en direct|trajet direct|directement|direct)\b"#) != nil
            || s.take(#"\b(?:avec )?(?:le )?moins (?:de |d')correspondances?\b"#) != nil {
            query.preference = .fewestTransfers
        } else if s.take(#"\b(?:avec )?(?:le )?moins (?:d'attente|attendre)\b|\bsans attendre\b"#) != nil {
            query.preference = .leastWaiting
        } else if s.take(#"\b(?:le )?plus (?:rapide|vite)\b|\bau plus vite\b"#) != nil {
            query.preference = .fastest
        }

        let wantsNow = s.take(#"\b(?:maintenant|tout de suite|immediatement|des que possible|now)\b"#) != nil

        // « dans 20 min », « dans une heure ».
        var relative: TimeInterval?
        if let m = s.take(#"\b(?:dans|d'ici) (\d{1,3}) ?(?:min|mins|minutes?|mn)\b"#), let n = m[1].flatMap(Double.init) {
            relative = n * 60
        } else if s.take(#"\bdans (?:une )?demi heure\b"#) != nil {
            relative = 1_800
        } else if let m = s.take(#"\bdans (une|un|\d) ?(?:h|heures?)\b"#), let v = m[1] {
            relative = (Double(v) ?? 1) * 3_600
        }

        // Jour et moment.
        var dayOffset: Int?
        var weekday: Int?
        var period: String?
        if s.take(#"\bapres demain\b"#) != nil { dayOffset = 2 }
        else if s.take(#"\bdemain\b"#) != nil { dayOffset = 1 }
        else if s.take(#"\baujourd'hui\b"#) != nil { dayOffset = 0 }
        if let m = s.take(#"\b(?:ce |cet |cette )(matin|midi|apres midi|aprem|soir|nuit)\b"#) {
            dayOffset = dayOffset ?? 0
            period = m[1]
        }
        let weekdays = ["dimanche": 1, "lundi": 2, "mardi": 3, "mercredi": 4, "jeudi": 5, "vendredi": 6, "samedi": 7]
        if let m = s.take(#"\b(?:ce |le )?(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)(?: prochain)?\b"#), let name = m[1] {
            weekday = weekdays[name]
        }

        // Heure, avec l'intention (« avant 9h », « départ 7h45 », « bus de 17h »).
        let arriveWords = #"avant|pour|d'ici|au plus tard(?: a)?|arrivee?(?: a| vers| pour| avant)?|arriver(?: a| vers| pour| avant)?|etre (?:la |sur place )?(?:a|pour|avant|vers)"#
        let departWords = #"apres|a partir de|des|en partant(?: a| vers)?|partir(?: a| vers)?|depart(?: a| vers)?|part(?: a| vers)?|de"#
        var clock: (hour: Int, minute: Int, kind: String?)?
        if let m = s.take(#"(?:\b(\#(arriveWords)|\#(departWords)|a|vers) )?\b(?:(\d{1,2}) ?(?:h|:|heures?) ?(\d{2})?|(midi|minuit))\b(?: (du matin|du soir|de l'apres midi|de l'aprem))?"#) {
            var hour: Int?
            var minute = 0
            if let h = m[2].flatMap({ Int($0) }) {
                hour = h
                minute = m[3].flatMap { Int($0) } ?? 0
            } else if let word = m[4] {
                hour = word == "midi" ? 12 : 0
            }
            if var h = hour, h <= 23, minute <= 59 {
                switch m[5] {
                case "du soir", "de l'apres midi", "de l'aprem": if h < 12 { h += 12 }
                case "du matin": if h == 12 { h = 0 }
                default: break
                }
                clock = (h, minute, m[1])
            }
        }
        if period == nil, let m = s.take(#"\b(?:le |en |dans la )?(matin|midi|apres midi|aprem|soir|soiree|nuit)\b"#) {
            period = m[1]
        }
        if let p = period, var c = clock, c.hour < 12, ["apres midi", "aprem", "soir", "soiree", "nuit"].contains(p) {
            c.hour += 12
            clock = c
        }

        // Date.
        let calendar = TransitClock.calendar
        let today = calendar.startOfDay(for: now)
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        var day: Date?
        if let dayOffset { day = calendar.date(byAdding: .day, value: dayOffset, to: today) }
        if let weekday {
            let delta = (weekday - calendar.component(.weekday, from: today) + 7) % 7
            var target = calendar.date(byAdding: .day, value: delta, to: today) ?? today
            if delta == 0, let clock, at(target, clock.hour, clock.minute) < now { target = calendar.date(byAdding: .day, value: 7, to: target) ?? target }
            day = target
        }
        if let relative {
            query.time = .departAt(now.addingTimeInterval(relative))
        } else if let clock {
            var date = at(day ?? today, clock.hour, clock.minute)
            if day == nil, date < now.addingTimeInterval(-600) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            let departs = clock.kind.map { $0.range(of: "^(?:\(departWords))$", options: .regularExpression) != nil } ?? false
            query.time = departs ? .departAt(date) : .arriveBy(date)
        } else if day != nil || period != nil {
            let hours = ["matin": 7, "midi": 12, "apres midi": 14, "aprem": 14, "soir": 18, "soiree": 19, "nuit": 21]
            let date = at(day ?? today, period.flatMap { hours[$0] } ?? 7, 0)
            if date > now {
                query.time = .departAt(date)
                query.isTimeApproximate = true
            } else {
                query.time = .now
            }
        } else if wantsNow {
            query.time = .now
        }

        // Lieux.
        s.replace(#"\b(?:en |au )?(?:partant|depart) (?:de |du |des |d')"#, with: " depuis ")
        let places = places(in: tokens(s.text))
        query.origin = places.origin.flatMap(placeTerm)
        query.destination = places.destination.flatMap(placeTerm)
        query.leftover = places.leftover
        return query
    }

    /// Alias (« maison », « boulot », « ici ») ou nom à chercher.
    public static func placeTerm(_ text: String) -> ParsedQuery.PlaceTerm? {
        let words = strip(tokens(normalize(text)), leading: articles.union(fillers).union(destinationWords), trailing: fillers)
        let name = words.joined(separator: " ").replacingOccurrences(of: "' ", with: "'")
        guard name.contains(where: \.isLetter) else { return nil }
        switch name {
        case "maison", "chez moi", "moi", "domicile", "la maison", "mon domicile", "ma maison", "chez nous", "home": return .home
        case "boulot", "travail", "taf", "taff", "bureau", "job", "mon boulot", "mon travail", "mon bureau", "work": return .work
        case "ici", "ma position", "position", "la ou je suis", "ou je suis", "position actuelle", "ma position actuelle": return .currentLocation
        default: return .named(name)
        }
    }

    // MARK: Découpage des lieux

    private static let fillers: Set<String> = [
        "je", "j'", "veux", "voudrais", "aimerais", "dois", "vais", "faut", "il", "que", "qu'", "comment", "aller", "me", "m'",
        "rendre", "rentrer", "retourner", "revenir", "y", "prendre", "bus", "car", "prochain", "prochaine", "prochains",
        "trajet", "itineraire", "horaire", "horaires", "quel", "quels", "quelle", "quelles", "quand", "stp", "svp", "busio",
        "s'il", "te", "plait", "partir", "arriver", "go", "on", "va",
    ]
    private static let articles: Set<String> = ["le", "la", "les", "l'", "un", "une", "mon", "ma", "mes"]
    private static let destinationWords: Set<String> = ["a", "au", "aux", "vers", "pour", "direction", "jusqu'", "chez"]
    private static let weakOrigins: Set<String> = ["de", "du", "des", "d'"]

    private static func places(in tokens: [String]) -> (origin: String?, destination: String?, leftover: String) {
        func segment(_ range: Range<Int>) -> String? {
            guard !range.isEmpty else { return nil }
            let kept = strip(Array(tokens[range]), leading: articles.union(fillers), trailing: fillers)
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }
        func destinationStart(_ index: Int) -> Int {
            // « jusqu'à », « jusqu'au » : la préposition fait deux mots.
            tokens[index] == "jusqu'" && index + 1 < tokens.count && ["a", "au", "aux"].contains(tokens[index + 1]) ? index + 2 : index + 1
        }

        if let arrow = tokens.firstIndex(of: "->") {
            return (segment(0..<arrow), segment((arrow + 1)..<tokens.count), "")
        }
        let destinationIndex = tokens.indices.first { destinationWords.contains(tokens[$0]) }

        if let from = tokens.firstIndex(of: "depuis") {
            if let d = destinationIndex, d < from {
                return (segment((from + 1)..<tokens.count), segment(destinationStart(d)..<from), leftover(tokens[..<d]))
            }
            if let d = tokens.indices.first(where: { $0 > from && destinationWords.contains(tokens[$0]) }) {
                return (segment((from + 1)..<d), segment(destinationStart(d)..<tokens.count), leftover(tokens[..<from]))
            }
            return (segment((from + 1)..<tokens.count), segment(0..<from), "")
        }

        let meaningful = tokens.indices.first { !fillers.contains(tokens[$0]) && !articles.contains(tokens[$0]) }
        if let first = meaningful, weakOrigins.contains(tokens[first]) {
            let d = tokens.indices.first { $0 > first && destinationWords.contains(tokens[$0]) }
            let originEnd = d ?? tokens.count
            return (segment((first + 1)..<originEnd), d.map { segment(destinationStart($0)..<tokens.count) } ?? nil, "")
        }
        if let d = destinationIndex {
            return (nil, segment(destinationStart(d)..<tokens.count), leftover(tokens[..<d]))
        }
        return (nil, segment(0..<tokens.count), "")
    }

    private static func leftover(_ words: ArraySlice<String>) -> String {
        words.filter { !fillers.contains($0) && !articles.contains($0) }.joined(separator: " ")
    }

    private static func strip(_ words: [String], leading: Set<String>, trailing: Set<String>) -> [String] {
        var words = words
        while let first = words.first, leading.contains(first) { words.removeFirst() }
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        return words
    }

    // MARK: Normalisation

    static func normalize(_ text: String) -> String {
        var s = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        for (from, to) in [("’", "'"), ("‘", "'"), ("`", "'"), ("´", "'"), ("→", " -> "), ("⇒", " -> "), ("=>", " -> ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: #"(\d)[.h](\d{2})\b"#, with: "$1h$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-(?!>)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,;!?.()"«»]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return " " + s.trimmingCharacters(in: .whitespaces) + " "
    }

    /// Mots, apostrophes détachées (« l'archipel » → « l' », « archipel »).
    static func tokens(_ text: String) -> [String] {
        text.split(separator: " ").flatMap { part -> [String] in
            let word = String(part)
            guard let apostrophe = word.firstIndex(of: "'") else { return [word] }
            let head = String(word[...apostrophe])
            let tail = String(word[word.index(after: apostrophe)...])
            return tail.isEmpty ? [head] : [head, tail]
        }
    }
}

/// Retire au fur et à mesure les morceaux compris.
private struct Scanner {
    var text: String

    init(_ text: String) { self.text = text }

    /// Première correspondance (groupes de capture, index 0 = tout), retirée du texte.
    mutating func take(_ pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups = (0..<match.numberOfRanges).map { index -> String? in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        text = ns.replacingCharacters(in: match.range, with: " ")
        return groups
    }

    mutating func replace(_ pattern: String, with replacement: String) {
        text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
