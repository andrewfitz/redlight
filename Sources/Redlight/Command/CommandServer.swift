import CoreFoundation
import Foundation

@MainActor
final class CommandServer {
    nonisolated static let portName = "com.redlight.app.command"
    // Set once during main-actor reservation, then only read; nonisolated deinit
    // invalidates it synchronously so the C callback cannot outlive its context.
    nonisolated(unsafe) private var port: CFMessagePort!
    private var source: CFRunLoopSource?
    private var isServicing = false
    private var handler: ((RedlightCommand) throws -> Status)?

    private init() {}

    /// Reserve first, before recovery or app construction. A cached same-process port is
    /// also a duplicate; CFMessagePortCreateLocal does not return nil for that case.
    static func reserve(name: String = portName) throws -> CommandServer {
        let owner = CommandServer()
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        var shouldFreeInfo = DarwinBoolean(false)
        let port = CFMessagePortCreateLocal(
            nil, name as CFString, commandPortCallback, &context, &shouldFreeInfo
        )
        guard let port, !shouldFreeInfo.boolValue else {
            // Never invalidate a cached port: it belongs to the existing owner.
            throw CommandError.unreachable("Redlight is already running or its command port cannot be reserved.")
        }
        owner.port = port
        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            throw CommandError.system("Unable to create the Redlight command run-loop source.")
        }
        owner.source = source
        return owner
    }

    func installHandler(_ handler: @escaping (RedlightCommand) throws -> Status) throws {
        guard !isServicing else {
            throw CommandError.system("The command server is already servicing requests.")
        }
        // Allocation already happened during reservation, before display recovery.
        guard let source else { throw CommandError.system("Redlight has no reserved command source.") }
        self.handler = handler
        isServicing = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    fileprivate func receive(_ data: Data) -> Data {
        let reply: CommandReply
        do {
            // Inspect the envelope before decoding command cases: a future client
            // can send an enum unknown to this version and still needs update advice.
            let header = try JSONDecoder().decode(CommandProtocolHeader.self, from: data)
            guard header.v == CommandRequest.currentVersion else {
                return encode(.failure(.system("Unsupported command protocol version; update Redlight.")))
            }
            let request = try JSONDecoder().decode(CommandRequest.self, from: data)
            guard let handler else {
                throw CommandError.unreachable("Redlight is still starting.")
            }
            reply = .success(try handler(request.command))
        } catch let error as CommandError {
            reply = .failure(error)
        } catch is DecodingError {
            reply = .failure(.invalidInput("Invalid command request JSON."))
        } catch {
            reply = .failure(.system("Unable to execute command: \(error.localizedDescription)"))
        }
        return encode(reply)
    }

    private func encode(_ reply: CommandReply) -> Data {
        // These wire values contain only finite validated scalars and strings.
        (try? JSONEncoder().encode(reply)) ?? Data("{\"v\":1,\"ok\":false,\"error\":{\"code\":\"system\",\"message\":\"Unable to encode command reply.\"}}".utf8)
    }

    deinit {
        if let port { CFMessagePortInvalidate(port) }
    }
}

private struct CommandProtocolHeader: Decodable { var v: Int }

private let commandPortCallback: CFMessagePortCallBack = { _, _, data, info in
    guard let data, let info else { return nil }
    let owner = Unmanaged<CommandServer>.fromOpaque(info).takeUnretainedValue()
    let requestData = data as Data
    // Servicing only occurs on the main run loop, including tracking common modes.
    let result = MainActor.assumeIsolated {
        owner.receive(requestData)
    }
    return Unmanaged.passRetained(result as CFData)
}
