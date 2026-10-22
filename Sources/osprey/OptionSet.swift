import Foundation
import OspreyCore

/// A very small option parser. Osprey has no third-party dependencies, so the
/// CLI reads `--key value`, `--key=value`, and `--flag` itself.
struct OptionSet {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []
    private let raw: [String]

    init(_ arguments: [String]) {
        raw = arguments
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    values[String(body[body.startIndex..<equals])] = String(body[body.index(after: equals)...])
                } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[body] = arguments[index + 1]
                    index += 1
                } else {
                    flags.insert(body)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    func integer(_ name: String, default fallback: Int) -> Int {
        guard let raw = values[name], let parsed = Int(raw) else { return fallback }
        return parsed
    }

    /// Every value given for a repeated option, in order.
    func repeated(_ name: String) -> [String] {
        var collected: [String] = []
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument == "--\(name)" {
                index += 1
                if index < raw.count { collected.append(raw[index]) }
            } else if argument.hasPrefix("--\(name)=") {
                collected.append(String(argument.dropFirst(name.count + 3)))
            }
            index += 1
        }
        return collected
    }
}
