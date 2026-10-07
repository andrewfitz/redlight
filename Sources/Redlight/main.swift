import AppKit
import Darwin
import Foundation

// Decide the role before any recovery, display manager or app services are initialized.
let exitCode = MainActor.assumeIsolated {
    EntryRouter.run(
        arguments: CommandLine.arguments,
        reserveOwner: {
            let server = try CommandServer.reserve()
            try EntryRouter.requireNoLegacyApplication()
            return server
        },
        runApplication: { server in
            AppDelegate.commandServer = server
            RedlightApp.main()
        },
        runCLI: { arguments in
            Task {
                let code = await RedlightCLI.run(arguments: arguments)
                exit(code)
            }
            dispatchMain()
        }
    )
}
exit(exitCode)
