import AVFoundation
import Foundation
import Speech

/// Un fragmento de la transcripción, con su ubicación temporal en el audio.
struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    let start: Double
    let end: Double
    let text: String

    // El identificador es de uso interno: al releer del disco se genera uno nuevo.
    private enum CodingKeys: String, CodingKey { case start, end, text }
}

/// Formatos en los que se puede exportar una transcripción.
enum ExportFormat: String, CaseIterable, Identifiable {
    case text, srt, vtt

    var id: String { rawValue }

    var ext: String {
        switch self {
        case .text: return "txt"
        case .srt:  return "srt"
        case .vtt:  return "vtt"
        }
    }

    var menuLabel: String {
        switch self {
        case .text: return "Texto (.txt)…"
        case .srt:  return "Subtítulos (.srt)…"
        case .vtt:  return "Subtítulos web (.vtt)…"
        }
    }

    var batchLabel: String {
        switch self {
        case .text: return "Guardar todas como texto…"
        case .srt:  return "Guardar todas como subtítulos (.srt)…"
        case .vtt:  return "Guardar todas como subtítulos web (.vtt)…"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case notAvailable
    case unsupportedLocale(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "La transcripción en el dispositivo no está disponible en este Mac."
        case .unsupportedLocale(let name):
            return "El idioma «\(name)» no está disponible para transcribir. Elige otro en el menú de idioma."
        case .emptyResult:
            return "No se detectó voz en el audio. Puede que el video solo tenga música, o que el idioma seleccionado no coincida con el hablado."
        }
    }
}

enum Transcriber {

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// Transcribe un archivo de audio con el motor on-device de macOS 26.
    /// `onProgress` recibe (fracción 0…1, o -1 si es indeterminada) y un texto de estado.
    static func transcribe(
        audio url: URL,
        locale: Locale,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [TranscriptSegment] {

        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notAvailable }

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            throw TranscriptionError.unsupportedLocale(name)
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // El modelo de cada idioma se descarga una sola vez y queda en el sistema.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            let name = Locale.current.localizedString(forIdentifier: resolved.identifier) ?? resolved.identifier
            onProgress(-1, "Descargando el modelo de voz para \(name)… (solo la primera vez)")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: resolved)

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Los resultados llegan por un AsyncSequence mientras el analizador avanza,
        // así que hay que consumirlos en paralelo al análisis.
        let collecting = Task {
            var collected: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let pieces = segments(from: result)
                collected.append(contentsOf: pieces)
                if duration > 0, let last = pieces.last {
                    onProgress(min(last.end / duration, 1.0), "Transcribiendo…")
                }
            }
            return collected
        }

        onProgress(0, "Transcribiendo…")
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collecting.cancel()
            throw error
        }

        let result = try await collecting.value
        guard !result.isEmpty else { throw TranscriptionError.emptyResult }
        return result
    }

    /// Transcribe una muestra corta y devuelve el texto y la confianza media.
    /// Se usa para adivinar el idioma: NO descarga modelos, solo prueba idiomas
    /// ya instalados (el que llame debe filtrarlos antes).
    static func probe(audio url: URL, locale: Locale) async throws -> (text: String, confidence: Double) {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notAvailable }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let collecting = Task { () -> (String, Double) in
            var text = ""
            var confidenceSum = 0.0
            var confidenceCount = 0
            for try await result in transcriber.results where result.isFinal {
                let attributed = result.text
                text += String(attributed.characters)
                for run in attributed.runs {
                    if let confidence = run.transcriptionConfidence {
                        confidenceSum += confidence
                        confidenceCount += 1
                    }
                }
            }
            let mean = confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : 0
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), mean)
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collecting.cancel()
            throw error
        }
        return try await collecting.value
    }

    /// Parte un resultado largo en frases usando las marcas de tiempo por palabra.
    private static func segments(from result: SpeechTranscriber.Result) -> [TranscriptSegment] {
        let attributed = result.text
        let fallbackStart = result.range.start.seconds
        let fallbackEnd = result.range.end.seconds

        var output: [TranscriptSegment] = []
        var buffer = ""
        var bufferStart: Double?
        var bufferEnd: Double?

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            let start = bufferStart ?? fallbackStart
            let end = bufferEnd ?? fallbackEnd
            bufferStart = nil
            bufferEnd = nil
            guard !text.isEmpty else { return }
            output.append(TranscriptSegment(start: start, end: max(end, start), text: text))
        }

        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            guard !piece.isEmpty else { continue }

            if let range = run.audioTimeRange {
                let start = range.start.seconds
                let end = range.end.seconds
                if start.isFinite { bufferStart = bufferStart ?? start }
                if end.isFinite { bufferEnd = max(bufferEnd ?? end, end) }
            }
            buffer += piece

            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let endsSentence = trimmed.last.map { ".?!…。？！".contains($0) } ?? false
            if endsSentence || trimmed.count >= 180 {
                flush()
            }
        }
        flush()

        if output.isEmpty {
            let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                output.append(TranscriptSegment(start: fallbackStart, end: fallbackEnd, text: text))
            }
        }
        return output
    }
}

extension Array where Element == TranscriptSegment {

    var plainText: String {
        map(\.text).joined(separator: " ")
    }

    var timestampedText: String {
        map { "[\($0.start.asClockTime)] \($0.text)" }.joined(separator: "\n")
    }

    var srt: String {
        enumerated().map { index, segment in
            let end = Swift.max(segment.end, segment.start + 0.4)
            return """
            \(index + 1)
            \(segment.start.asSRTTime) --> \(end.asSRTTime)
            \(segment.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT: el formato de subtítulos que entienden los reproductores web.
    /// Se diferencia del SRT en la cabecera y en el punto decimal.
    var vtt: String {
        let cues = enumerated().map { index, segment -> String in
            let end = Swift.max(segment.end, segment.start + 0.4)
            return """
            \(index + 1)
            \(segment.start.asVTTTime) --> \(end.asVTTTime)
            \(segment.text)
            """
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n" + cues + "\n"
    }

    func exported(as format: ExportFormat, withTimestamps: Bool) -> String {
        switch format {
        case .text: return withTimestamps ? timestampedText : plainText
        case .srt:  return srt
        case .vtt:  return vtt
        }
    }
}

extension Double {
    var asClockTime: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var asSRTTime: String {
        guard isFinite, self >= 0 else { return "00:00:00,000" }
        let ms = Int((self * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Igual que el SRT pero con punto decimal, como exige WebVTT.
    var asVTTTime: String {
        guard isFinite, self >= 0 else { return "00:00:00.000" }
        let ms = Int((self * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
