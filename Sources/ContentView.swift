import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Divisor arrastrable: en ventanas estrechas el título de la
            // transcripción se queda sin sitio, así que el usuario decide
            // cuánto espacio le da a la cola.
            HSplitView {
                QueueColumn()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 290)
                DetailColumn()
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(dropOverlay)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .onAppear { model.loadLocales() }
    }

    // MARK: - Encabezado

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.83, blue: 0.86),
                                                  Color(red: 0.98, green: 0.16, blue: 0.36)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("TokScribe")
                    .font(.system(size: 16, weight: .semibold))
                Text("Transcribe varios TikToks a la vez, en tu Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if !model.lastMessage.isEmpty {
                Text(model.lastMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Arrastrar y soltar

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(Color.accentColor.opacity(0.06))
            .padding(6)
            .opacity(isDropTarget ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.enqueueFiles(urls.sorted { $0.path < $1.path })
        }
        return true
    }
}

// MARK: - Columna izquierda: entrada + cola

private struct QueueColumn: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputArea
            Divider()
            queueList
            if !model.jobs.isEmpty {
                Divider()
                queueFooter
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.inputText.isEmpty {
                    Text("Pega uno o varios enlaces de TikTok,\nuno por línea…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.inputText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .focused($inputFocused)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

            localePicker
            cookiePicker
            keepVideoControls

            HStack(spacing: 8) {
                Button {
                    model.openFiles()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Añadir archivos de video o audio")

                Button {
                    model.enqueueFromInput()
                    inputFocused = false
                } label: {
                    Text("Transcribir").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private var localePicker: some View {
        Picker("Idioma", selection: $model.localeID) {
            Text("Automático").tag(AppModel.autoLocaleID)
            if !model.availableLocales.isEmpty {
                Divider()
                ForEach(model.availableLocales, id: \.identifier) { locale in
                    Text(AppModel.displayName(for: locale)).tag(locale.identifier)
                }
            }
        }
        .help("«Automático» detecta el idioma de cada video entre los que ya tienes instalados. Si no, elige uno fijo para toda la cola.")
    }

    private var cookiePicker: some View {
        Picker("Cookies", selection: $model.cookies) {
            ForEach(CookieSource.allCases) { source in
                Text(source == .none ? "Sin cookies" : source.label).tag(source)
            }
        }
        .help("Usa la sesión de un navegador si TikTok pide iniciar sesión")
    }

    private var keepVideoControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $model.keepVideo) {
                Text("Conservar el video descargado")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .help("Guarda una copia del video en una carpeta; si no, solo se transcribe y se borra")

            if model.keepVideo {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(model.keepFolderName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Cambiar…") { model.chooseKeepFolder() }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
                .padding(.leading, 20)
            }
        }
    }

    private var queueList: some View {
        Group {
            if model.jobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("La cola está vacía")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedJobID) {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                            .tag(job.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var queueFooter: some View {
        HStack(spacing: 8) {
            if model.isProcessing {
                Button(role: .cancel) {
                    model.cancelAll()
                } label: {
                    Label("Detener", systemImage: "stop.fill")
                        .font(.system(size: 11))
                }
            } else {
                Button {
                    model.clearFinished()
                } label: {
                    Label("Limpiar", systemImage: "xmark.bin")
                        .font(.system(size: 11))
                }
                .disabled(!model.jobs.contains { $0.state.isFinished })
            }

            Spacer()

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.batchLabel) { model.saveAll(as: format) }
                }
                Divider()
                Button("Copiar todas") { model.copyAll() }
            } label: {
                Label("Exportar todo", systemImage: "square.and.arrow.down.on.square")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.doneJobs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Fila de la cola

private struct JobRow: View {
    @ObservedObject var job: TranscriptionJob
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if job.state == .working {
                    if job.progress >= 0 {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    } else {
                        Text(job.statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(job.statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(job.state == .failed ? .orange : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            trailingButton
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if job.state == .failed || job.state == .cancelled {
                Button("Reintentar") { model.retry(job) }
            }
            if job.state == .working {
                Button("Saltar este") { model.skip(job) }
            }
            Button("Quitar de la cola", role: .destructive) { model.remove(job) }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .working:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var trailingButton: some View {
        if job.state == .working {
            Button { model.skip(job) } label: {
                Image(systemName: "stop.circle")
            }
            .help("Saltar este video")
        } else {
            Button { model.remove(job) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .help("Quitar de la cola")
        }
    }
}

// MARK: - Columna derecha: transcripción

private struct DetailColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let job = model.selectedJob {
            JobDetail(job: job)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.quote")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text("La transcripción aparecerá aquí")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Pega varios enlaces de TikTok en la izquierda, o arrastra videos y audios a la ventana. Se transcriben uno tras otro.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

private struct JobDetail: View {
    @ObservedObject var job: TranscriptionJob
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    /// Barra de acciones. Usa iconos con descripción emergente en vez de texto:
    /// a 760 px —el ancho mínimo de la ventana— las etiquetas se partían en
    /// varias líneas y se cortaban. Con iconos el ancho es fijo y nunca rompe.
    private var toolbar: some View {
        HStack(spacing: 8) {
            // Se trunca al final, no por el medio: los títulos suelen ser frases
            // y se entienden mucho mejor leyendo el principio.
            Text(job.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(job.title)

            if let language = job.languageBadge {
                Text(language)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(job.languageIsCertain ? .secondary : Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(job.languageIsCertain
                                       ? Color.secondary.opacity(0.14)
                                       : Color.orange.opacity(0.14))
                    )
                    .layoutPriority(1)
                    .help(job.languageNote ?? "")
            }

            Spacer(minLength: 8)

            if job.state == .done, !job.segments.isEmpty {
                Toggle(isOn: $model.showTimestamps) {
                    Image(systemName: "clock")
                }
                .toggleStyle(.button)
                .help(model.showTimestamps ? "Ocultar las marcas de tiempo" : "Mostrar las marcas de tiempo")

                Button { model.copySelected() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copiar esta transcripción")

                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.menuLabel) { model.saveSelected(as: format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .help("Guardar esta transcripción")
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch job.state {
        case .done where !job.segments.isEmpty:
            transcript
        case .failed:
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text("No se pudo transcribir")
                        .font(.system(size: 13, weight: .medium))
                    Text(job.errorMessage ?? "Error desconocido")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 380)
                    Button("Reintentar") { model.retry(job) }
                        .padding(.top, 4)
                }
            }
        case .working:
            centered {
                VStack(spacing: 12) {
                    if job.progress >= 0 {
                        ProgressView(value: job.progress).frame(width: 200)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(job.statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .cancelled:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Cancelado")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Reintentar") { model.retry(job) }
                }
            }
        default:
            centered {
                Text("En espera de su turno…")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollView {
            if model.showTimestamps {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(job.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(segment.start.asClockTime)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(segment.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(20)
            } else {
                Text(job.segments.plainText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}
