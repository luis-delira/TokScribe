// Prueba de la cola: mete varios archivos en el AppModel real y espera a que terminen.
import Foundation

@main
struct BatchTest {
    @MainActor
    static func main() async {
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else {
            print("Uso: batch-test <archivo1> <archivo2> …")
            exit(2)
        }

        let model = AppModel()
        model.localeID = AppModel.autoLocaleID   // detección automática de idioma
        model.enqueueFiles(Array(files))

        print("Encolados \(model.jobs.count) trabajos. Procesando…\n")

        // Espera a que la cola se vacíe.
        while model.isProcessing || model.jobs.contains(where: { $0.state == .pending || $0.state == .working }) {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        print("=== Resultado de la cola ===")
        var ok = 0
        for (index, job) in model.jobs.enumerated() {
            let state: String
            switch job.state {
            case .done: state = "OK"; ok += 1
            case .failed: state = "ERROR: \(job.errorMessage ?? "")"
            case .cancelled: state = "CANCELADO"
            default: state = "\(job.state)"
            }
            print("\n[\(index + 1)] \(job.title) — \(state)")
            if let note = job.languageNote { print("    \(note)") }
            if job.state == .done {
                print("    fragmentos: \(job.segments.count)")
                print("    texto: \(job.segments.plainText.prefix(90))…")
            }
        }
        print("\n\(ok)/\(model.jobs.count) transcritos correctamente")
        exit(ok == model.jobs.count ? 0 : 1)
    }
}
