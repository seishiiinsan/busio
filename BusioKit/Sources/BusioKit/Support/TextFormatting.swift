import Foundation

public enum TextFormatting {
    /// Clé de recherche : minuscules, sans accents ni ponctuation.
    public static func searchKey(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let lowercaseWords: Set<String> = ["de", "du", "des", "la", "le", "les", "et", "sur", "en", "aux", "au"]
    private static let uppercaseWords: Set<String> = ["SNCF", "ZI", "ZA", "ZAC", "IUT", "CCI", "EHPAD", "RN", "II", "III", "IV"]
    private static let accented: [String: String] = [
        "college": "Collège", "ecole": "École", "ecoles": "Écoles", "eveche": "Évêché",
        "lameilhe": "Lameilhé", "capelanie": "Capelanié", "bisseous": "Bisséous", "moliere": "Molière",
        "hopital": "Hôpital", "lycee": "Lycée", "eglise": "Église", "cite": "Cité", "prefecture": "Préfecture",
        "cimetiere": "Cimetière", "theatre": "Théâtre", "general": "Général", "mediatheque": "Médiathèque",
        "residence": "Résidence", "universite": "Université", "aeroport": "Aéroport", "plombieres": "Plombières",
        "republique": "République", "liberation": "Libération", "chateau": "Château",
        "pre": "Pré", "vallee": "Vallée",
    ]

    /// « COLLEGE JEAN-JAURES » → « Collège Jean-Jaures », « PLAN D'EAU » → « Plan d'Eau ».
    public static func prettyStopName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == trimmed.uppercased() else { return trimmed }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        return words.enumerated().map { index, word in
            prettyWord(String(word), isFirst: index == 0)
        }.joined(separator: " ")
    }

    private static func prettyWord(_ word: String, isFirst: Bool) -> String {
        if uppercaseWords.contains(word) { return word }
        if word.contains("-") {
            return word.split(separator: "-").map { prettyWord(String($0), isFirst: true) }.joined(separator: "-")
        }
        if let apostrophe = word.firstIndex(where: { $0 == "'" || $0 == "’" }) {
            let head = String(word[..<apostrophe]).lowercased()
            let tail = String(word[word.index(after: apostrophe)...])
            let prettyHead = isFirst ? head.capitalized : head
            return prettyHead + "'" + prettyWord(tail, isFirst: true)
        }
        let lower = word.lowercased()
        if let first = lower.first, first.isNumber {
            return lower // « 1er », « 8 »
        }
        if !isFirst, lowercaseWords.contains(lower) { return lower }
        if let accent = accented[lower] { return accent }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
