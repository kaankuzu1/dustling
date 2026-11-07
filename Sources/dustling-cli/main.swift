import DustlingCore
import Foundation

let usage = """
Usage: dustling-cli <command> [options]

Commands:
  doctor                              Check Full Disk Access, free space and problems
  scan                                Show where space can be freed
  clean [--include <categoryID>...]   Move junk to the Trash (asks first)
  apps                                List installed apps with sizes
  uninstall <name|number> [--all]     Move an app and its leftovers to the Trash (asks first)
  startup                             List login items and background agents
  startup disable|enable <label>      Turn a startup item off or on (asks first)
  history                             List past runs
  restore <run-id-prefix> [--path <p>]  Put a run's items back from the Trash
  empty-trash                         Permanently delete everything in the Trash (asks first)

Options:
  --yes                               Answer yes to the confirmation (for scripts)

Cleaning and uninstalling only move items to the Trash. Empty Trash is the only permanent delete.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32

if let command = arguments.first {
    let rest = Array(arguments.dropFirst())
    switch command {
    case "doctor": exitCode = await Commands.doctor()
    case "scan": exitCode = await Commands.scan()
    case "clean": exitCode = await Commands.clean(rest)
    case "apps": exitCode = Commands.apps()
    case "uninstall": exitCode = await Commands.uninstall(rest)
    case "startup": exitCode = Commands.startup(rest)
    case "history": exitCode = Commands.history()
    case "restore": exitCode = Commands.restore(rest)
    case "empty-trash": exitCode = Commands.emptyTrash(rest)
    case "help", "--help", "-h":
        print(usage)
        exitCode = 0
    default:
        Format.printError("Unknown command: \(command)\n")
        Format.printError(usage)
        exitCode = 1
    }
} else {
    Format.printError(usage)
    exitCode = 1
}
exit(exitCode)
