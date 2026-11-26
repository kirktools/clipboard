import AppKit
import ClipboardCore
import Darwin

@MainActor
@main
struct ClipboardMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--apply-update" {
            Darwin.exit(UpdateInstaller.runHelper(jobPath: args[2]))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
