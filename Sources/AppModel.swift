import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {

    /// Valor especial del selector de idioma: detectar automáticamente.
    static let autoLocaleID = "auto"

    // Entrada y opciones (todas se recuerdan entre sesiones)
    @Published var inputText: String = ""

    @Published var localeID: String = AppModel.savedLocaleID {
        didSet { UserDefaults.standard.set(localeID, forKey: "localeID") }
    }
    @Published var cookies: CookieSource = AppModel.savedCookies {
        didSet { UserDefaults.standard.set(cookies.rawValue, forKey: "cookies") }
    }
    @Published var showTimestamps: Bool = UserDefaults.standard.bool(forKey: "showTimestamps") {
        didSet { UserDefaults.standard.set(showTimestamps, forKey: "showTimestamps") }
    }

    // Conservar el video descargado (se recuerda entre sesiones)
    @Published var keepVideo: Bool = UserDefaults.standard.bool(forKey: "keepVideo") {
        didSet { UserDefaults.standard.set(keepVideo, forKey: "keepVideo") }
    }
    @Published var keepFolderPath: String = AppModel.savedKeepFolderPath {
        didSet { UserDefaults.standard.set(keepFolderPath, forKey: "keepFolder") }
    }

    // Cola
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published var selectedJobID: UUID?
    @Published private(set) var isProcessing = false
    @Published private(set) var availableLocales: [Locale] = []
    @Published private(set) var lastMessage: String = ""

    // Procesamiento
    private var processingTask: Task<Void, Never>?
    private var currentJobTask: Task<Void, Error>?
    private var activeFetcher: MediaFetcher?
    private var batchCancelled = false

    var isYtdlpBundled: Bool { ToolLocator.isYtdlpBundled }

    // MARK: - Conservar el video

    /// Carpeta donde se copian los videos cuando `keepVideo` está activo.
    var keepFolderURL: URL {
        keepFolderPath.isEmpty ? Self.defaultKeepFolder : URL(fileURLWithPath: keepFolderPath)
    }

    /// Nombre corto de esa carpeta, para mostrarlo en la interfaz.
    var keepFolderName: String {
        keepFolderURL.lastPathComponent
    }

    func chooseKeepFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = keepFolderURL
        panel.prompt = "Elegir"
        panel.message = "Elige dónde guardar los videos descargados"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keepFolderPath = url.path
        keepVideo = true
    }

    private static var defaultKeepFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private static var savedKeepFolderPath: String {
        let stored = UserDefaults.standard.string(forKey: "keepFolder") ?? ""
        return stored.isEmpty ? defaultKeepFolder.path : stored
    }

    private static var savedLocaleID: String {
        UserDefaults.standard.string(forKey: "localeID") ?? autoLocaleID
    }

    private static var savedCookies: CookieSource {
        guard let raw = UserDefaults.standard.string(forKey: "cookies") else { return .none }
        return CookieSource(rawValue: raw) ?? .none
    }

    // MARK: - Biblioteca guardada

    init() {
        let restored = LibraryStore.load().map(TranscriptionJob.init(restoring:))
        jobs = restored
        selectedJobID = restored.last?.id
        updateSummary()
    }

    /// Vuelca a disco las transcripciones terminadas. Se llama tras cada cambio
    /// que las afecte, para que un cierre inesperado no borre el trabajo hecho.
    private func persistLibrary() {
        let entries = jobs.compactMap(\.storableEntry)
        LibraryStore.save(entries)
    }

    /// Borra todo el historial guardado, incluidas las entradas en disco.
    func clearLibrary() {
        jobs.removeAll { $0.state.isFinished }
        LibraryStore.removeAll()
        selectedJobID = jobs.first?.id
        updateSummary()
    }

    // MARK: - Idiomas

    func loadLocales() {
        guard availableLocales.isEmpty else { return }
        Task {
            let supported = await Transcriber.supportedLocales()
            let sorted = supported.sorted { a, b in
                Self.displayName(for: a).localizedCaseInsensitiveCompare(Self.displayName(for: b)) == .orderedAscending
            }
            await MainActor.run {
                self.availableLocales = sorted
                // «Automático» es un valor válido aunque no esté en la lista de
                // idiomas: si no se excluye aquí, se sustituye por uno concreto
                // en cada arranque y la detección automática deja de aplicarse.
                let needsFallback = !sorted.isEmpty
                    && self.localeID != Self.autoLocaleID
                    && !sorted.contains { $0.identifier == self.localeID }
                if needsFallback {
                    let preferred = sorted.first { $0.identifier.hasPrefix("es") } ?? sorted[0]
                    self.localeID = preferred.identifier
                }
            }
        }
    }

    // MARK: - Añadir a la cola

    /// Convierte cada línea no vacía del cuadro de texto en un trabajo.
    func enqueueFromInput() {
        let links = inputText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !links.isEmpty else { return }

        for link in links {
            append(TranscriptionJob(source: .url(link)))
        }
        inputText = ""
        ensureProcessing()
    }

    func enqueueFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            append(TranscriptionJob(source: .file(url)))
        }
        ensureProcessing()
    }

    func pasteIntoInput() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = inputText.isEmpty ? trimmed : inputText + "\n" + trimmed
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        panel.message = "Elige uno o varios videos o audios para transcribir"
        panel.prompt = "Añadir a la cola"
        guard panel.runModal() == .OK else { return }
        enqueueFiles(panel.urls)
    }

    private func append(_ job: TranscriptionJob) {
        jobs.append(job)
        if selectedJobID == nil { selectedJobID = job.id }
    }

    // MARK: - Cola: control

    func cancelAll() {
        batchCancelled = true
        activeFetcher?.cancel()
        currentJobTask?.cancel()
        for job in jobs where job.state == .pending {
            job.markCancelled()
        }
    }

    /// Salta un trabajo concreto: si está corriendo lo interrumpe, si espera lo marca cancelado.
    func skip(_ job: TranscriptionJob) {
        switch job.state {
        case .working:
            activeFetcher?.cancel()
            currentJobTask?.cancel()
        case .pending:
            job.markCancelled()
        default:
            break
        }
    }

    func retry(_ job: TranscriptionJob) {
        guard job.state.isFinished else { return }
        job.state = .pending
        job.progress = 0
        job.statusText = "En espera"
        job.errorMessage = nil
        ensureProcessing()
    }

    func remove(_ job: TranscriptionJob) {
        if job.state == .working { skip(job) }
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id {
            selectedJobID = jobs.first?.id
        }
        persistLibrary()
        updateSummary()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        if let selected = selectedJobID, !jobs.contains(where: { $0.id == selected }) {
            selectedJobID = jobs.first?.id
        }
        persistLibrary()
        updateSummary()
    }

    // MARK: - Procesamiento en cola

    private func ensureProcessing() {
        guard processingTask == nil else { return }
        batchCancelled = false
        isProcessing = true
        processingTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !batchCancelled, let job = jobs.first(where: { $0.state == .pending }) {
            await process(job)
        }
        processingTask = nil
        isProcessing = false
        batchCancelled = false
        updateSummary()
    }

    private func process(_ job: TranscriptionJob) async {
        if selectedJob == nil || selectedIsFinished { selectedJobID = job.id }

        let fetcher = MediaFetcher()
        activeFetcher = fetcher
        let task = Task { try await self.runJob(job, fetcher: fetcher) }
        currentJobTask = task

        do {
            try await task.value
        } catch is CancellationError {
            job.markCancelled()
        } catch {
            job.markFailed(error.localizedDescription)
        }

        activeFetcher = nil
        currentJobTask = nil
        // Se guarda tras cada video, no al final de la tanda: si algo interrumpe
        // la app a mitad de una cola larga, no se pierde lo ya transcrito.
        persistLibrary()
        updateSummary()
    }

    private func runJob(_ job: TranscriptionJob, fetcher: MediaFetcher) async throws {
        job.markWorking()
        fetcher.resetCancellation()

        let dir = try Self.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report: @Sendable (Double, String) -> Void = { [weak job] value, text in
            Task { @MainActor in
                job?.progress = value
                job?.statusText = text
            }
        }

        let cookieSource = cookies
        let keepDestination = keepVideo ? keepFolderURL : nil
        let media: FetchedMedia
        switch job.source {
        case .url(let link):
            media = try await fetcher.downloadAudio(from: link, cookies: cookieSource, keepVideoIn: keepDestination, into: dir, onProgress: report)
        case .file(let url):
            media = try await fetcher.extractAudio(from: url, into: dir, onProgress: report)
        }
        try Task.checkCancellation()

        let locale = try await resolveLocale(for: job, audio: media.audioURL, in: dir, report: report)
        try Task.checkCancellation()

        let segments = try await Transcriber.transcribe(audio: media.audioURL, locale: locale, onProgress: report)
        try Task.checkCancellation()

        job.markDone(title: media.title, segments: segments)
    }

    /// Decide con qué idioma transcribir. En modo automático sondea los idiomas
    /// instalados sobre una muestra corta y anota cuál eligió.
    private func resolveLocale(
        for job: TranscriptionJob,
        audio: URL,
        in dir: URL,
        report: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Locale {
        guard localeID == Self.autoLocaleID else {
            return Locale(identifier: localeID)
        }

        let installed = await Transcriber.installedLocales()
        let candidates = LanguageDetector.candidates(from: installed)

        // Con menos de dos idiomas instalados no hay nada que distinguir.
        guard candidates.count >= 2 else {
            let fallback = candidates.first ?? Locale(identifier: Self.defaultLocaleID)
            await MainActor.run { job.languageNote = "Idioma: \(Self.languageName(for: fallback))" }
            return fallback
        }

        report(-1, "Detectando idioma…")
        let sample = dir.appendingPathComponent("sample.wav")
        do {
            try AudioExtractor.writeSample(from: audio, to: sample, maxSeconds: 18)
        } catch {
            // Si no se pudo recortar la muestra, se transcribe con el idioma del sistema.
            let fallback = Locale(identifier: Self.defaultLocaleID)
            await MainActor.run { job.languageNote = "Idioma: \(Self.languageName(for: fallback))" }
            return fallback
        }
        try Task.checkCancellation()

        let detected = await LanguageDetector.detect(sampleAt: sample, among: candidates)
        try? FileManager.default.removeItem(at: sample)

        let chosen = detected?.locale ?? Locale(identifier: Self.defaultLocaleID)
        let name = Self.languageName(for: chosen)
        await MainActor.run {
            if let detected, detected.coherent {
                job.languageNote = "Detectado: \(name)"
            } else {
                job.languageNote = "Idioma: \(name) (sin certeza)"
            }
        }
        return chosen
    }

    // MARK: - Resumen

    private var selectedIsFinished: Bool {
        selectedJob?.state.isFinished ?? true
    }

    private func updateSummary() {
        let done = jobs.filter { $0.state == .done }.count
        let failed = jobs.filter { $0.state == .failed }.count
        let pending = jobs.filter { $0.state == .pending || $0.state == .working }.count

        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) en cola") }
        if done > 0 { parts.append("\(done) \(done == 1 ? "lista" : "listas")") }
        if failed > 0 { parts.append("\(failed) con error") }
        lastMessage = parts.joined(separator: " · ")
    }

    private static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokScribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Selección y exportación

    var selectedJob: TranscriptionJob? {
        guard let id = selectedJobID else { return nil }
        return jobs.first { $0.id == id }
    }

    var doneJobs: [TranscriptionJob] {
        jobs.filter { $0.state == .done && !$0.segments.isEmpty }
    }

    func transcriptText(for job: TranscriptionJob) -> String {
        showTimestamps ? job.segments.timestampedText : job.segments.plainText
    }

    func copySelected() {
        guard let job = selectedJob, !job.segments.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(for: job), forType: .string)
        lastMessage = "Copiado al portapapeles"
    }

    func saveSelected(as format: ExportFormat) {
        guard let job = selectedJob, !job.segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(Self.safeFileName(job.title)).\(format.ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = job.segments.exported(as: format, withTimestamps: showTimestamps)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastMessage = "Guardado en \(url.lastPathComponent)"
        } catch {
            lastMessage = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    /// Guarda todas las transcripciones terminadas como archivos sueltos en una carpeta.
    func saveAll(as format: ExportFormat) {
        let ready = doneJobs
        guard !ready.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Guardar aquí"
        panel.message = "Elige una carpeta para \(ready.count) transcripciones (una por video)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var used = Set<String>()
        var saved = 0
        for job in ready {
            let name = Self.uniqueName(Self.safeFileName(job.title), ext: format.ext, used: &used)
            let content = job.segments.exported(as: format, withTimestamps: showTimestamps)
            if (try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil {
                saved += 1
            }
        }
        lastMessage = "Guardadas \(saved) transcripciones en \(dir.lastPathComponent)"
    }

    func copyAll() {
        let ready = doneJobs
        guard !ready.isEmpty else { return }
        let combined = ready.map { job in
            "# \(job.title)\n\(transcriptText(for: job))"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        lastMessage = "Copiadas \(ready.count) transcripciones"
    }

    // MARK: - Utilidades

    private static func safeFileName(_ raw: String) -> String {
        let base = raw.isEmpty ? "Transcripción" : raw
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Transcripción" : trimmed
    }

    private static func uniqueName(_ base: String, ext: String, used: inout Set<String>) -> String {
        var candidate = "\(base).\(ext)"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// La interfaz está escrita en español, así que los nombres de idioma se
    /// piden también en español y no en el idioma del sistema. Si no, en un Mac
    /// configurado en inglés aparecía «Detectado: Spanish».
    private static let namingLocale = Locale(identifier: "es")

    static func displayName(for locale: Locale) -> String {
        let name = namingLocale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Solo el nombre del idioma, sin país (para la nota de detección).
    static func languageName(for locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? String(locale.identifier.prefix(2))
        let name = namingLocale.localizedString(forLanguageCode: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static var defaultLocaleID: String {
        let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return current.isEmpty ? "es-MX" : current
    }
}
