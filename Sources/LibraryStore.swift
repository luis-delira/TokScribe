import Foundation

/// Guarda en disco las transcripciones terminadas para que sobrevivan al cierre
/// de la app. Solo se conserva el resultado: ni el audio ni el video, que se
/// borran al terminar cada trabajo.
enum LibraryStore {

    /// Tope de entradas guardadas; al superarlo se descartan las más antiguas.
    static let maxEntries = 300

    struct Entry: Codable, Identifiable {
        let id: UUID
        let title: String
        let sourceKind: String     // "url" o "file"
        let sourceValue: String
        let languageNote: String?
        let segments: [TranscriptSegment]
        let savedAt: Date
    }

    // MARK: - Ubicación

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TokScribe", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("library.json")
    }

    // MARK: - Lectura y escritura

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else {
            // Un archivo corrupto no debe impedir que la app arranque.
            return []
        }
        return entries
    }

    @discardableResult
    static func save(_ entries: [Entry]) -> Bool {
        let trimmed = entries.count > maxEntries
            ? Array(entries.suffix(maxEntries))
            : entries

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(trimmed)
            // Escritura atómica: un corte de luz no deja el archivo a medias.
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
