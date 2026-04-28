import SwiftUI
import AppKit
import SwiftTerm

struct SwiftTermContainer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.caretViewTracksFocus = false  // always render filled block, even when unfocused
        if let mono = NSFont(name: "SF Mono", size: 12) ?? NSFont(name: "Menlo", size: 12) {
            term.font = mono
        }
        context.coordinator.term = term
        context.coordinator.startShell()
        context.coordinator.observeReset()
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var term: LocalProcessTerminalView?
        private var resetObserver: NSObjectProtocol?

        func observeReset() {
            resetObserver = NotificationCenter.default.addObserver(
                forName: .floatnoteTerminalReset, object: nil, queue: .main
            ) { [weak self] _ in
                self?.restart()
            }
        }

        deinit {
            if let o = resetObserver { NotificationCenter.default.removeObserver(o) }
        }

        func startShell() {
            guard let term = term else { return }
            // Disable caret blink — steady block cursor.
            term.terminal?.setCursorStyle(.steadyBlock)
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home = NSHomeDirectory()
            let preferredCwd = "/Users/cagdas.agirtas/Library/CloudStorage/OneDrive-SunExpress/chatbot-files/agentforce-implementation"
            let cwd = FileManager.default.fileExists(atPath: preferredCwd) ? preferredCwd : home
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            env.append("HOME=\(home)")
            term.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-\(NSString(string: shell).lastPathComponent)",
                currentDirectory: cwd
            )
        }

        func restart() {
            term?.process.terminate()
            DispatchQueue.main.async { [weak self] in self?.startShell() }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
