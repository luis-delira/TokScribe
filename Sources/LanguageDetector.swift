import Foundation
import NaturalLanguage

/// Adivina el idioma hablado en un audio probando varios modelos de voz sobre
/// una muestra corta. Combina dos señales:
///   1. La confianza media que reporta cada modelo.
///   2. Si NaturalLanguage detecta en el texto resultante el mismo idioma del modelo.
/// El modelo correcto produce palabras coherentes y con confianza alta; uno
/// equivocado produce texto fragmentado que NaturalLanguage identifica como otra cosa.
enum LanguageDetector {

    struct Result {
        let locale: Locale
        let confidence: Double
        let coherent: Bool
    }

    /// `candidates` deben estar ya instalados: el sondeo no descarga modelos.
    static func detect(sampleAt url: URL, among candidates: [Locale]) async -> Result? {
        var best: Result?
        var bestScore = -1.0

        for locale in candidates {
            guard let probe = try? await Transcriber.probe(audio: url, locale: locale) else { continue }

            let words = probe.text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
            guard words >= 2 else { continue }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(probe.text)
            let detected = recognizer.dominantLanguage?.rawValue
            let localeLanguage = locale.language.languageCode?.identifier ?? String(locale.identifier.prefix(2))
            let coherent = detected == localeLanguage

            // La coherencia pesa fuerte; la confianza desempata entre candidatos coherentes.
            let score = probe.confidence + (coherent ? 1.0 : 0.0)
            if score > bestScore {
                bestScore = score
                best = Result(locale: locale, confidence: probe.confidence, coherent: coherent)
            }
        }
        return best
    }

    /// Reduce la lista de idiomas instalados a un conjunto razonable para sondear:
    /// una variante por idioma, con el del sistema y el inglés al frente, y un tope.
    /// Para cada idioma prefiere la variante de la región del sistema (así la nota
    /// dice «es_MX» en México en vez de una variante cualquiera).
    static func candidates(from installed: [Locale], limit: Int = 5) -> [Locale] {
        let systemRegion = Locale.current.region?.identifier

        func languageCode(_ locale: Locale) -> String {
            locale.language.languageCode?.identifier ?? String(locale.identifier.prefix(2))
        }

        // Agrupa por idioma y escoge, dentro de cada uno, la variante regional del sistema.
        var byLanguage: [String: Locale] = [:]
        for locale in installed {
            let code = languageCode(locale)
            if let existing = byLanguage[code] {
                if locale.region?.identifier == systemRegion, existing.region?.identifier != systemRegion {
                    byLanguage[code] = locale
                }
            } else {
                byLanguage[code] = locale
            }
        }

        let systemLanguage = Locale.current.language.languageCode?.identifier
        let ordered = byLanguage.values.sorted { a, b in
            rank(a, systemLanguage) < rank(b, systemLanguage)
        }
        return Array(ordered.prefix(limit))
    }

    private static func rank(_ locale: Locale, _ systemLanguage: String?) -> Int {
        let code = locale.language.languageCode?.identifier
        if code == systemLanguage { return 0 }
        if code == "en" { return 1 }
        return 2
    }
}
