// Prueba de la copia "conservar el video": nombre limpio, sin sobrescribir, crea carpeta.
// Uso:  ./build/keep-test <archivo-video-de-ejemplo>
import Foundation

@main
struct KeepTest {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else { print("Uso: keep-test <video>"); exit(2) }
        let source = URL(fileURLWithPath: args[1])

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-test-\(UUID().uuidString)/subcarpeta/nueva")
        // Ojo: la carpeta destino NO existe todavía; saveCopy debe crearla.

        print("Destino (inexistente aún): \(dest.path)\n")

        MediaFetcher.saveCopy(of: source, named: "Mi Video Genial", into: dest)
        MediaFetcher.saveCopy(of: source, named: "Mi Video Genial", into: dest)   // mismo nombre → (2)
        MediaFetcher.saveCopy(of: source, named: "cosas / raras : en \"nombre\"", into: dest) // caracteres inválidos

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.sorted() ?? []
        print("Archivos resultantes:")
        for f in files { print("  • \(f)") }

        let ok = files.contains("Mi Video Genial.mp4")
            && files.contains("Mi Video Genial (2).mp4")
            && files.contains { $0.hasPrefix("cosas - raras") }
            && files.count == 3
        print("\n\(ok ? "OK ✓ nombres limpios, sin colisión y carpeta creada" : "FALLÓ ✗")")

        try? FileManager.default.removeItem(at: dest.deletingLastPathComponent().deletingLastPathComponent())
        exit(ok ? 0 : 1)
    }
}
