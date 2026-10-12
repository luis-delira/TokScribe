import SwiftUI

@main
struct TokScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("TokScribe") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Añadir archivos…") { model.openFiles() }
                    .keyboardShortcut("o")
                Button("Pegar enlaces") { model.pasteIntoInput() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Transcribir la cola") { model.enqueueFromInput() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Guardar selección como texto…") { model.saveSelected(as: .text) }
                    .keyboardShortcut("s")
                    .disabled(model.selectedJob?.segments.isEmpty ?? true)
                Button("Guardar selección como subtítulos (.srt)…") { model.saveSelected(as: .srt) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.selectedJob?.segments.isEmpty ?? true)
                Button("Guardar selección como subtítulos web (.vtt)…") { model.saveSelected(as: .vtt) }
                    .disabled(model.selectedJob?.segments.isEmpty ?? true)
                Divider()
                Button("Guardar todas como texto…") { model.saveAll(as: .text) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.doneJobs.isEmpty)
                Divider()
                Button("Borrar historial guardado…") { model.clearLibrary() }
                    .disabled(model.jobs.allSatisfy { !$0.state.isFinished })
            }
        }
    }
}
