import Foundation

/// Un elemento de la cola: un enlace o un archivo con su propio estado y resultado.
@MainActor
final class TranscriptionJob: ObservableObject, Identifiable {

    enum State: Equatable {
        case pending      // en espera de su turno
        case working      // descargando o transcribiendo ahora
        case done         // terminado con éxito
        case failed       // error
        case cancelled    // saltado por el usuario

        var isFinished: Bool {
            self == .done || self == .failed || self == .cancelled
        }
    }

    enum Source {
        case url(String)
        case file(URL)
    }

    let id = UUID()
    let source: Source

    @Published var title: String
    @Published var state: State = .pending
    @Published var progress: Double = 0        // -1 = indeterminado
    @Published var statusText: String = "En espera"
    @Published var segments: [TranscriptSegment] = []
    @Published var errorMessage: String?
    @Published var languageNote: String?

    /// Cuándo se completó. Solo se rellena en trabajos terminados.
    private(set) var savedAt: Date?

    init(source: Source) {
        self.source = source
        switch source {
        case .url(let link):
            title = TranscriptionJob.shortName(for: link)
        case .file(let url):
            title = url.deletingPathExtension().lastPathComponent
        }
    }

    /// Reconstruye un trabajo ya terminado a partir de lo guardado en disco.
    init(restoring entry: LibraryStore.Entry) {
        source = entry.sourceKind == "url"
            ? .url(entry.sourceValue)
            : .file(URL(fileURLWithPath: entry.sourceValue))
        title = entry.title
        segments = entry.segments
        languageNote = entry.languageNote
        state = .done
        progress = 1
        statusText = "Listo · \(entry.segments.count) \(entry.segments.count == 1 ? "fragmento" : "fragmentos")"
        savedAt = entry.savedAt
    }

    /// Representación guardable. Solo tiene sentido para trabajos con resultado.
    var storableEntry: LibraryStore.Entry? {
        guard state == .done, !segments.isEmpty else { return nil }
        let kind: String
        let value: String
        switch source {
        case .url(let link):  kind = "url";  value = link
        case .file(let url):  kind = "file"; value = url.path
        }
        return LibraryStore.Entry(
            id: id,
            title: title,
            sourceKind: kind,
            sourceValue: value,
            languageNote: languageNote,
            segments: segments,
            savedAt: savedAt ?? Date()
        )
    }

    // MARK: - Transiciones de estado

    func markWorking() {
        state = .working
        progress = -1
        errorMessage = nil
        languageNote = nil
        statusText = "Preparando…"
    }

    func markDone(title newTitle: String, segments newSegments: [TranscriptSegment]) {
        if !newTitle.isEmpty { title = newTitle }
        segments = newSegments
        state = .done
        progress = 1
        savedAt = Date()
        statusText = "Listo · \(newSegments.count) \(newSegments.count == 1 ? "fragmento" : "fragmentos")"
    }

    func markFailed(_ message: String) {
        guard state != .done else { return }
        state = .failed
        progress = 0
        errorMessage = message
        statusText = "Error"
    }

    func markCancelled() {
        guard !state.isFinished else { return }
        state = .cancelled
        progress = 0
        statusText = "Cancelado"
    }

    // MARK: - Presentación

    var sourceDescription: String {
        switch source {
        case .url(let link): return link
        case .file(let url): return url.path
        }
    }

    /// Nombre corto del idioma para la etiqueta de la barra: «Español» en vez de
    /// «Detectado: Español». El texto completo se muestra al pasar el ratón, así
    /// la etiqueta ocupa lo mínimo y le deja sitio al título.
    /// Se calcula al vuelo para que también funcione con lo ya guardado en disco.
    var languageBadge: String? {
        guard let note = languageNote else { return nil }
        var text = note
        for prefix in ["Detectado: ", "Idioma: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        if let range = text.range(of: " (sin certeza)") {
            text.removeSubrange(range)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `false` cuando el idioma se eligió sin que las señales coincidieran.
    var languageIsCertain: Bool {
        languageNote?.hasPrefix("Detectado:") ?? false
    }

    private static func shortName(for link: String) -> String {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return link }
        let user = url.pathComponents.first { $0.hasPrefix("@") }
        let idPart = url.pathComponents.last { $0.allSatisfy(\.isNumber) && !$0.isEmpty }
        switch (user, idPart) {
        case let (user?, id?): return "\(user) · \(id)"
        case let (user?, nil): return user
        case let (nil, id?): return "TikTok \(id)"
        default: return url.host ?? link
        }
    }
}
