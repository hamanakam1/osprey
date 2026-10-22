import Foundation
import OspreyCore

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    try OspreyCLI(arguments: arguments).run()
} catch {
    FileHandle.standardError.write(Data("osprey: \(error)\n".utf8))
    exit(1)
}
