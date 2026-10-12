import AVFoundation
import Foundation

/// Extrae audio usando solo AVFoundation (lo que macOS ya trae).
/// Evita depender de ffmpeg, que además de pesar viene con licencia GPL.
enum AudioExtractor {

    enum ExtractionError: LocalizedError {
        case noAudioTrack
        case readFailed(String)
        case unreadableFormat

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "El archivo no contiene ninguna pista de audio."
            case .readFailed(let reason):
                return "No se pudo leer el audio: \(reason)"
            case .unreadableFormat:
                return "macOS no puede abrir este formato de archivo."
            }
        }
    }

    /// Formato que espera el motor de voz: PCM 16 bits, 16 kHz, mono.
    static let sampleRate = 16_000.0

    /// Convierte cualquier contenedor legible por macOS (mp4, mov, m4a, mp3, wav…)
    /// en un WAV mono de 16 kHz listo para transcribir.
    static func extractWAV(
        from source: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {

        let asset = AVURLAsset(url: source)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ExtractionError.unreadableFormat
        }
        guard let track = tracks.first else { throw ExtractionError.noAudioTrack }

        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExtractionError.readFailed(error.localizedDescription)
        }

        // AVAssetReaderTrackOutput remezcla y remuestrea por nosotros.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.unreadableFormat }
        reader.add(output)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { throw ExtractionError.unreadableFormat }

        let file = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard reader.startReading() else {
            throw ExtractionError.readFailed(reader.error?.localizedDescription ?? "error desconocido")
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            if let block = CMSampleBufferGetDataBuffer(sample) {
                let byteCount = CMBlockBufferGetDataLength(block)
                let frames = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)

                if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                    buffer.frameLength = frames
                    if let channel = buffer.int16ChannelData?[0] {
                        CMBlockBufferCopyDataBytes(
                            block,
                            atOffset: 0,
                            dataLength: byteCount,
                            destination: channel
                        )
                        try file.write(from: buffer)
                    }
                }
            }

            if totalDuration > 0 {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if seconds.isFinite {
                    onProgress(min(seconds / totalDuration, 1.0))
                }
            }
            CMSampleBufferInvalidate(sample)
        }

        switch reader.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw ExtractionError.readFailed(reader.error?.localizedDescription ?? "lectura incompleta")
        }
    }

    /// Copia los primeros `maxSeconds` de un WAV a otro archivo, para detectar
    /// el idioma sin transcribir el clip entero.
    static func writeSample(from wav: URL, to destination: URL, maxSeconds: Double) throws {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        let wanted = AVAudioFrameCount(min(Double(input.length), maxSeconds * format.sampleRate))
        guard wanted > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else {
            throw ExtractionError.readFailed("la muestra quedó vacía")
        }
        try input.read(into: buffer, frameCount: wanted)

        let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings)
        try output.write(from: buffer)
    }
}
