// Prueba de la detección de idioma: para cada audio, extrae una muestra y
// reporta qué idioma eligió el detector.
// Uso:  ./build/detect-test <audio1> <audio2> …
import Foundation
import Speech

@main
struct DetectTest {
    static func main() async {
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else {
            print("Uso: detect-test <audio1> <audio2> …")
            exit(2)
        }

        let installed = await SpeechTranscriber.installedLocales
        let candidates = LanguageDetector.candidates(from: installed)
        print("Candidatos a sondear: \(candidates.map { $0.identifier })\n")

        let tmp = FileManager.default.temporaryDirectory
        var passed = 0

        for file in files {
            let sample = tmp.appendingPathComponent("detect-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: sample) }
            do {
                // Los .wav ya vienen a 16 kHz; los demás se pasan por AVFoundation antes.
                let wav: URL
                if file.pathExtension.lowercased() == "wav" {
                    wav = file
                } else {
                    wav = tmp.appendingPathComponent("full-\(UUID().uuidString).wav")
                    try await AudioExtractor.extractWAV(from: file, to: wav)
                }
                try AudioExtractor.writeSample(from: wav, to: sample, maxSeconds: 18)

                if let result = await LanguageDetector.detect(sampleAt: sample, among: candidates) {
                    let tag = result.coherent ? "✓ seguro" : "≈ sin certeza"
                    print("\(file.lastPathComponent) → \(result.locale.identifier)  (confianza \(String(format: "%.3f", result.confidence)), \(tag))")
                    passed += 1
                } else {
                    print("\(file.lastPathComponent) → no se pudo detectar")
                }
            } catch {
                print("\(file.lastPathComponent) → ERROR: \(error.localizedDescription)")
            }
        }
        print("\n\(passed)/\(files.count) detectados")
    }
}
