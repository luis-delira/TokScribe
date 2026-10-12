// Prueba del motor desde la terminal (sirve para diagnosticar).
// Uso:  ./build/tokscribe-cli <archivo de video o audio> [código-de-idioma]
import Foundation

private let log: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

@main
struct TranscribeCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("Uso: tokscribe-cli <archivo> [idioma, p. ej. es-MX]")
            exit(2)
        }
        let source = URL(fileURLWithPath: arguments[1])
        let locale = Locale(identifier: arguments.count > 2 ? arguments[2] : "es-MX")

        do {
            // Extracción nativa a WAV 16 kHz mono, igual que hace la app.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokscribe-cli-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let audio = workDir.appendingPathComponent("audio.wav")
            log("Extrayendo audio con AVFoundation…")
            try await AudioExtractor.extractWAV(from: source, to: audio)

            let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size]) as? Int ?? 0
            log("WAV listo (\(size) bytes)")

            let segments = try await Transcriber.transcribe(audio: audio, locale: locale) { progress, status in
                log("[\(progress < 0 ? -1 : Int(progress * 100))%] \(status)")
            }
            print("--- \(segments.count) fragmentos ---")
            print(segments.timestampedText)
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
}
