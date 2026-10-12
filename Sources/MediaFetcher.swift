import AVFoundation
import Foundation

struct FetchedMedia {
    let audioURL: URL
    let title: String
}

enum MediaError: LocalizedError {
    case missingTool(String, hint: String)
    case toolFailed(tool: String, message: String)
    case cancelled
    case noMediaProduced
    case noAudioInAnyFormat(String?)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name, let hint):
            return "No se encontró «\(name)». \(hint)"
        case .toolFailed(let tool, let message):
            return "\(tool) falló:\n\(message)"
        case .cancelled:
            return "Operación cancelada."
        case .noMediaProduced:
            return "La descarga terminó pero no se generó ningún archivo. Es posible que la publicación sea una galería de fotos sin video."
        case .noAudioInAnyFormat:
            return """
            Este video no trae sonido en ninguno de los formatos que ofrece la \
            plataforma, así que no hay nada que transcribir.

            Suele pasar con galerías de fotos, con videos mudos o con \
            publicaciones cuyo audio se ha retirado por derechos de autor.
            """
        }
    }
}

enum CookieSource: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, edge, brave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Sin cookies"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        }
    }

    var ytdlpValue: String? { self == .none ? nil : rawValue }
}

enum ToolLocator {
    /// Busca primero la copia empaquetada dentro de la app, para que funcione en
    /// un Mac sin Homebrew; si no está, cae a la instalación del sistema.
    static func find(_ name: String) -> URL? {
        if let bundled = bundledURL(for: name) { return bundled }

        let directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSHomeDirectory() + "/.local/bin",
        ]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func bundledURL(for name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var isYtdlpBundled: Bool { bundledURL(for: "yt-dlp") != nil }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Descarga con yt-dlp y prepara el audio. La conversión es nativa (AVFoundation),
/// así que la app no necesita ffmpeg ni instalado ni empaquetado.
final class MediaFetcher: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Process?
    private var userCancelled = false

    func cancel() {
        lock.lock()
        userCancelled = true
        current?.terminate()
        lock.unlock()
    }

    func resetCancellation() {
        lock.lock()
        userCancelled = false
        lock.unlock()
    }

    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userCancelled
    }

    // MARK: - Selección de formato

    /// TikTok anuncia `acodec=aac` en sus formatos H.265 (bytevc1) pero los sirve
    /// **sin pista de audio**. Como el H.265 suele ser el de mayor calidad, un
    /// selector normal lo elige y llega un archivo mudo. Por eso se pide H.264
    /// primero y, si aun así llega sin audio, se reintenta con otro formato.
    ///
    /// Sin ffmpeg no se pueden fusionar pistas separadas, así que todos los
    /// candidatos son archivos ya combinados o de solo audio.
    private static let formatSelectors = [
        "ba[ext=m4a]/ba/b[vcodec*=h264]/b[vcodec*=avc]/b[ext=mp4]/b",
        "download/b[vcodec*=h264]/bv*[vcodec*=h264]+ba/b",
    ]

    private func arguments(
        for selector: String,
        link: String,
        cookies: CookieSource,
        workDir: URL
    ) -> [String] {
        var arguments = [
            "--no-playlist",
            "--no-simulate",
            "--newline",
            "--progress",
            "--no-warnings",
            "--print", "###META###%(title)s",
            "-f", selector,
            "-o", workDir.appendingPathComponent("media.%(ext)s").path,
        ]
        if let browser = cookies.ytdlpValue {
            arguments += ["--cookies-from-browser", browser]
        }
        arguments.append(link)
        return arguments
    }

    /// Borra los restos de un intento anterior para no confundirlos con el nuevo.
    private static func clearDownloads(in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for file in contents where file.lastPathComponent.hasPrefix("media.") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Descarga desde una URL

    func downloadAudio(
        from link: String,
        cookies: CookieSource,
        keepVideoIn keepFolder: URL?,
        into workDir: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchedMedia {

        guard let ytdlp = ToolLocator.find("yt-dlp") else {
            throw MediaError.missingTool("yt-dlp", hint: "Vuelve a instalar la app, o instálalo con:  brew install yt-dlp")
        }

        var lastNoAudio: Error?

        // Puede hacer falta más de un intento: ver el comentario de `formatSelectors`.
        for (attempt, selector) in Self.formatSelectors.enumerated() {
            if wasCancelled { throw MediaError.cancelled }
            Self.clearDownloads(in: workDir)

            let isRetry = attempt > 0
            onProgress(-1, isRetry ? "Reintentando con otro formato…" : "Descargando el video…")

            let title = TitleBox()
            let result = try await run(ytdlp, arguments(for: selector, link: link, cookies: cookies, workDir: workDir)) { line in
                if line.hasPrefix("###META###") {
                    title.value = String(line.dropFirst("###META###".count)).trimmingCharacters(in: .whitespaces)
                } else if let percent = Self.downloadPercent(in: line) {
                    let label = isRetry ? "Reintentando… \(Int(percent))%" : "Descargando el video… \(Int(percent))%"
                    onProgress(percent / 100 * 0.85, label)
                }
            }

            if wasCancelled { throw MediaError.cancelled }
            guard result.status == 0 else {
                throw MediaError.toolFailed(tool: "yt-dlp", message: Self.friendlyError(result.stderr + "\n" + result.stdout))
            }
            guard let downloaded = Self.downloadedFile(in: workDir) else {
                throw MediaError.noMediaProduced
            }

            let name = title.value.isEmpty ? "Transcripción" : title.value

            onProgress(0.9, "Extrayendo el audio…")
            do {
                let audioURL = try await prepareAudio(from: downloaded, into: workDir)

                // Solo se conserva el video cuando ya se sabe que sirve.
                if let keepFolder {
                    Self.saveCopy(of: downloaded, named: name, into: keepFolder)
                }
                try? FileManager.default.removeItem(at: downloaded)
                return FetchedMedia(audioURL: audioURL, title: name)

            } catch let error as AudioExtractor.ExtractionError {
                guard case .noAudioTrack = error else { throw error }
                // El archivo llegó mudo: se descarta y se prueba el siguiente selector.
                lastNoAudio = error
                try? FileManager.default.removeItem(at: downloaded)
                continue
            }
        }

        throw MediaError.noAudioInAnyFormat(lastNoAudio?.localizedDescription)
    }

    // MARK: - Archivo local de video o audio

    func extractAudio(
        from file: URL,
        into workDir: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchedMedia {
        onProgress(-1, "Preparando el audio…")
        let audioURL = try await prepareAudio(from: file, into: workDir)
        return FetchedMedia(audioURL: audioURL, title: file.deletingPathExtension().lastPathComponent)
    }

    /// Conversión nativa. Si macOS no entiende el contenedor (por ejemplo .webm)
    /// y el usuario tiene ffmpeg instalado, se usa como respaldo.
    private func prepareAudio(from source: URL, into workDir: URL) async throws -> URL {
        let audioURL = workDir.appendingPathComponent("audio.wav")
        do {
            try await AudioExtractor.extractWAV(from: source, to: audioURL)
            return audioURL
        } catch let error as AudioExtractor.ExtractionError {
            // Un archivo sin pista de audio no lo arregla ninguna herramienta.
            if case .noAudioTrack = error { throw error }
            guard let ffmpeg = ToolLocator.find("ffmpeg") else { throw error }
            try? FileManager.default.removeItem(at: audioURL)
            try await convert(source, to: audioURL, using: ffmpeg)
            return audioURL
        }
    }

    private func convert(_ source: URL, to destination: URL, using ffmpeg: URL) async throws {
        let result = try await run(ffmpeg, [
            "-nostdin", "-y",
            "-i", source.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            destination.path,
        ], onLine: { _ in })

        if wasCancelled { throw MediaError.cancelled }
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw MediaError.toolFailed(tool: "ffmpeg", message: Self.friendlyError(result.stderr))
        }
    }

    // MARK: - Ejecución de procesos

    private func run(
        _ executable: URL,
        _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
            process.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let buffers = OutputBuffers(onLine: onLine)

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                buffers.appendStdout(handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                buffers.appendStderr(handle.availableData)
            }

            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffers.appendStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
                buffers.appendStderr(errPipe.fileHandleForReading.readDataToEndOfFile())

                self.lock.lock()
                self.current = nil
                self.lock.unlock()

                continuation.resume(returning: ProcessResult(
                    status: finished.terminationStatus,
                    stdout: buffers.stdoutText,
                    stderr: buffers.stderrText
                ))
            }

            do {
                lock.lock()
                current = process
                lock.unlock()
                try process.run()
            } catch {
                process.terminationHandler = nil
                lock.lock()
                current = nil
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Utilidades

    /// yt-dlp elige la extensión, así que se toma el archivo `media.*` más grande.
    private static func downloadedFile(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("media.") }
            .max { a, b in
                let sizeA = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sizeB = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sizeA < sizeB
            }
    }

    /// Copia el video a la carpeta elegida, con un nombre limpio y sin pisar otros.
    static func saveCopy(of file: URL, named title: String, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
        let base = safeFileName(title)
        var destination = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        try? FileManager.default.copyItem(at: file, to: destination)
    }

    private static func safeFileName(_ raw: String) -> String {
        let base = raw.isEmpty ? "Video" : raw
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Video" : trimmed
    }

    private static func downloadPercent(in line: String) -> Double? {
        guard line.contains("[download]"),
              let range = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        return Double(line[range].dropLast())
    }

    private static func friendlyError(_ raw: String) -> String {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let errors = lines.filter { $0.contains("ERROR") || $0.contains("error") }
        let chosen = errors.isEmpty ? Array(lines.suffix(3)) : Array(errors.suffix(3))
        var message = chosen.joined(separator: "\n")

        if message.contains("Unable to extract") || message.contains("Unsupported URL") {
            message += "\n\nSi el enlace es correcto, puede que TikTok haya cambiado algo por dentro. Actualiza yt-dlp:  brew upgrade yt-dlp"
        }
        if message.contains("login") || message.contains("cookies") || message.contains("captcha") {
            message += "\n\nEste video podría requerir sesión iniciada: elige un navegador en «Cookies» y vuelve a intentarlo."
        }
        if message.contains("IP address is blocked") || message.contains("blocked from accessing") {
            message += "\n\nTikTok está bloqueando esta conexión. Suele resolverse eligiendo tu navegador en «Cookies» (ahí va tu sesión de TikTok) o probando desde otra red."
        }
        if message.contains("Video unavailable") || message.contains("not exist") {
            message += "\n\nRevisa que el enlace siga activo y sea público."
        }
        return message.isEmpty ? raw : message
    }
}

/// Caja con candado para el título, que llega desde otro hilo.
private final class TitleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Acumula la salida de un proceso y entrega líneas completas al observador.
private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        out.append(data)
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(pending[pending.startIndex..<index]))
            pending = String(pending[pending.index(after: index)...])
        }
        lock.unlock()
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    var stdoutText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
