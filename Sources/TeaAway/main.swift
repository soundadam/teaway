import Darwin
import TeaAwayCore

let application = TeaAwayApplication()
let status = application.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
