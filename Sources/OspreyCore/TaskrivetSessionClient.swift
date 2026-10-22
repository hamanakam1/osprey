import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// A read-only client for the Taskrivet local session service.
///
/// Osprey never writes to a terminal. It authenticates with the same private
/// token Taskrivet uses, lists the open tabs, and follows their output. Every
/// command is sent as a single JSON line, exactly like the desktop client.
public final class TaskrivetSessionClient {
    public enum Event: Sendable {
        case data(terminalID: String, seq: Int, text: String)
        case exit(terminalID: String, code: Int?)
    }

    public enum ClientError: Error, CustomStringConvertible, Sendable {
        case socketUnavailable(String)
        case authenticationFailed
        case connectionLost(String)
        case protocolError(String)
        case notConnected

        public var description: String {
            switch self {
            case .socketUnavailable(let message): return message
            case .authenticationFailed: return "The Taskrivet session service rejected the local token."
            case .connectionLost(let message): return message
            case .protocolError(let message): return message
            case .notConnected: return "Not connected to the Taskrivet session service."
            }
        }
    }

    private let socketPath: String
    private let token: String
    private var descriptor: Int32 = -1
    private var buffer = Data()
    private var nextRequestID = 0
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private let lock = NSLock()
    private var readerThread: Thread?
    private var closed = false

    /// Called for every event the service pushes. Set before calling `connect`.
    public var onEvent: ((Event) -> Void)?

    public init(socketURL: URL, token: String) {
        self.socketPath = socketURL.path
        self.token = token
    }

    deinit { close() }

    // MARK: - Connection

    public func connect() throws {
        guard descriptor < 0 else { return }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw ClientError.socketUnavailable("Could not create a local socket.")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(handle)
            throw ClientError.socketUnavailable("The session socket path is too long for a local socket.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(handle, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(handle)
            throw ClientError.socketUnavailable("The Taskrivet session service is not reachable at \(socketPath): \(message)")
        }
        descriptor = handle

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "osprey.session.reader"
        thread.start()
        readerThread = thread

        do {
            _ = try request("hello", extra: ["token": token, "version": 1])
        } catch let error as ClientError {
            close()
            throw error
        } catch {
            close()
            throw ClientError.authenticationFailed
        }
    }

    public func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        let handle = descriptor
        descriptor = -1
        lock.unlock()
        guard !alreadyClosed, handle >= 0 else { return }
        Darwin.shutdown(handle, Int32(SHUT_RDWR))
        Darwin.close(handle)
    }

    // MARK: - Requests

    /// Lists the tabs the session service currently owns.
    public func list() throws -> [TaskrivetTerminal] {
        let raw = try request("list")
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            throw ClientError.protocolError("The session service returned an unreadable tab list.")
        }
        do {
            return try JSONDecoder().decode([TaskrivetTerminal].self, from: data)
        } catch {
            throw ClientError.protocolError("The session service returned tabs Osprey could not read: \(error)")
        }
    }

    private func request(_ op: String, extra: [String: Any] = [:]) throws -> Any {
        lock.lock()
        guard descriptor >= 0 else {
            lock.unlock()
            throw ClientError.notConnected
        }
        nextRequestID += 1
        let id = nextRequestID
        var payload: [String: Any] = ["id": id, "op": op]
        for (key, value) in extra { payload[key] = value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        lock.unlock()

        let sema = DispatchSemaphore(value: 0)
        var outcome: Result<Any, Error>?
        lock.lock()
        pending[id] = { result in
            outcome = result
            sema.signal()
        }
        lock.unlock()

        try writeLine(data)
        if sema.wait(timeout: .now() + 10) == .timedOut {
            lock.lock()
            pending[id] = nil
            lock.unlock()
            throw ClientError.protocolError("The Taskrivet session service did not answer a \(op) request in time.")
        }
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw ClientError.protocolError("The Taskrivet session service closed the connection.")
        }
    }

    private func writeLine(_ data: Data) throws {
        var line = data
        line.append(0x0A)
        lock.lock()
        let handle = descriptor
        lock.unlock()
        guard handle >= 0 else { throw ClientError.notConnected }
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(handle, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw ClientError.connectionLost("The Taskrivet session service closed the connection.")
                }
                offset += written
            }
        }
    }

    // MARK: - Reading

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            lock.lock()
            let handle = descriptor
            let isClosed = closed
            lock.unlock()
            if isClosed || handle < 0 { return }
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(handle, raw.baseAddress!, raw.count)
            }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                drainBuffer()
            } else if count == 0 {
                failPending(ClientError.connectionLost("The Taskrivet session service closed the connection."))
                return
            } else if errno != EINTR {
                failPending(ClientError.connectionLost("The Taskrivet session service connection failed."))
                return
            }
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            handle(line: lineData)
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let event = object["event"] as? String, let payload = object["payload"] as? [String: Any] {
            switch event {
            case "terminal:data":
                let id = payload["id"] as? String ?? ""
                let seq = payload["seq"] as? Int ?? 0
                let text = payload["data"] as? String ?? ""
                onEvent?(.data(terminalID: id, seq: seq, text: text))
            case "terminal:exit":
                let id = payload["id"] as? String ?? ""
                let code = payload["exitCode"] as? Int
                onEvent?(.exit(terminalID: id, code: code))
            default:
                break
            }
            return
        }
        guard let id = object["id"] as? Int else { return }
        lock.lock()
        let handler = pending.removeValue(forKey: id)
        lock.unlock()
        guard let handler else { return }
        if let error = object["error"] as? String {
            handler(.failure(ClientError.protocolError(error)))
        } else if let result = object["result"] {
            handler(.success(result))
        } else {
            handler(.failure(ClientError.protocolError("The session service returned an empty response.")))
        }
    }

    private func failPending(_ error: Error) {
        lock.lock()
        let handlers = pending.values
        pending.removeAll()
        lock.unlock()
        for handler in handlers { handler(.failure(error)) }
    }
}

/// Reads the private token the session service expects.
///
/// The token file must be a regular file owned by the operator with mode 0600.
/// Osprey refuses anything else rather than reading a world-readable secret.
public enum SessionTokenReader {
    public static func read(at url: URL) throws -> String {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
            throw TaskrivetSessionClient.ClientError.socketUnavailable("The session token is not a regular file.")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o077 == 0 else {
            throw TaskrivetSessionClient.ClientError.socketUnavailable("The session token file is readable by other users. Refusing to read it.")
        }
        let data = try Data(contentsOf: url)
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw TaskrivetSessionClient.ClientError.socketUnavailable("The session token file is empty.")
        }
        return token
    }
}
