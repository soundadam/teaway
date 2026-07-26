import Darwin
import TeaAwayCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == TeaAwayPrivilegeConfiguration.internalCommand {
  exit(PrivilegedHelperMain.run(arguments: Array(arguments.dropFirst())))
}

let application = TeaAwayApplication()
let status = application.run(arguments: arguments)
exit(status)
