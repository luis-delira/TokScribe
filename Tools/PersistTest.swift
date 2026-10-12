// Prueba de persistencia y formatos de exportación.
// Simula: transcribir → cerrar la app → volver a abrirla.
// Uso:  ./build/persist-test <archivo1> <archivo2>
import Foundation

@main
struct PersistTest {
    @MainActor
    static func main() async {
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { print("Uso: persist-test <archivo…>"); exit(2) }

        // Se respalda la biblioteca real para no tocar el trabajo del usuario.
        let backup = try? Data(contentsOf: LibraryStore.fileURL)
        LibraryStore.removeAll()
        defer {
            if let backup { try? backup.write(to: LibraryStore.fileURL) }
            else { LibraryStore.removeAll() }
        }

        var ok = true
        func check(_ label: String, _ passed: Bool) {
            print("  \(passed ? "✓" : "✗") \(label)")
            if !passed { ok = false }
        }

        // ─── Sesión 1: transcribir ───
        print("SESIÓN 1 — transcribiendo \(files.count) archivos…")
        let first = AppModel()
        first.localeID = AppModel.autoLocaleID
        first.enqueueFiles(Array(files))

        while first.isProcessing || first.jobs.contains(where: { $0.state == .pending || $0.state == .working }) {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let doneCount = first.doneJobs.count
        let titles = first.doneJobs.map(\.title)
        let firstText = first.doneJobs.first?.segments.plainText ?? ""
        print("  transcritos: \(doneCount)/\(files.count)")

        // ─── Se "cierra" la app: el AppModel desaparece ───
        print("\nARCHIVO EN DISCO")
        let exists = FileManager.default.fileExists(atPath: LibraryStore.fileURL.path)
        check("library.json creado", exists)
        let size = (try? FileManager.default.attributesOfItem(atPath: LibraryStore.fileURL.path)[.size]) as? Int ?? 0
        check("tiene contenido (\(size) bytes)", size > 0)

        // ─── Sesión 2: se abre la app de nuevo ───
        print("\nSESIÓN 2 — reabriendo la app (AppModel nuevo)…")
        let second = AppModel()
        check("recupera \(doneCount) transcripciones", second.jobs.count == doneCount)
        check("todas en estado 'listo'", second.jobs.allSatisfy { $0.state == .done })
        check("conserva los títulos", second.jobs.map(\.title) == titles)
        check("conserva el texto íntegro", second.jobs.first?.segments.plainText == firstText)
        check("conserva las marcas de tiempo", second.jobs.first?.segments.first?.start != nil)
        check("conserva el idioma detectado", second.jobs.first?.languageNote != nil)

        if let note = second.jobs.first?.languageNote {
            print("     (\(note))")
        }

        // ─── Formatos de exportación ───
        print("\nFORMATOS DE EXPORTACIÓN")
        guard let segments = second.jobs.first?.segments, !segments.isEmpty else {
            print("  ✗ sin segmentos que exportar"); exit(1)
        }
        let vtt = segments.vtt
        let srt = segments.srt
        check("VTT empieza por la cabecera WEBVTT", vtt.hasPrefix("WEBVTT\n\n"))
        check("VTT usa punto decimal (00:00:00.000)", vtt.contains(" --> ") && vtt.range(of: #"\d\d:\d\d:\d\d\.\d\d\d --> "#, options: .regularExpression) != nil)
        check("VTT no usa coma decimal", !vtt.contains(",") || vtt.range(of: #"\d\d:\d\d:\d\d,\d\d\d"#, options: .regularExpression) == nil)
        check("SRT sigue usando coma decimal", srt.range(of: #"\d\d:\d\d:\d\d,\d\d\d --> "#, options: .regularExpression) != nil)
        check("ambos tienen \(segments.count) subtítulos", vtt.components(separatedBy: " --> ").count - 1 == segments.count)

        print("\n─── primeras líneas del .vtt ───")
        print(vtt.split(separator: "\n").prefix(6).joined(separator: "\n"))

        // ─── Borrar historial ───
        print("\nBORRAR HISTORIAL")
        second.clearLibrary()
        check("vacía la cola", second.jobs.isEmpty)
        check("borra el archivo del disco", !FileManager.default.fileExists(atPath: LibraryStore.fileURL.path))

        print("\n\(ok ? "TODO CORRECTO ✓" : "HAY FALLOS ✗")")
        exit(ok ? 0 : 1)
    }
}
