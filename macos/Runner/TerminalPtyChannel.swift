import Cocoa
import FlutterMacOS
import Darwin

final class TerminalPtyChannel: NSObject, FlutterStreamHandler {
    private static var shared: TerminalPtyChannel?

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let lock = NSLock()
    private var eventSink: FlutterEventSink?
    private var nextSessionId = 1
    private var sessions: [Int: TerminalPtySession] = [:]

    static func register(with controller: FlutterViewController) {
        shared = TerminalPtyChannel(binaryMessenger: controller.engine.binaryMessenger)
    }

    private init(binaryMessenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.hxlive.termora/terminal_pty",
            binaryMessenger: binaryMessenger
        )
        eventChannel = FlutterEventChannel(
            name: "com.hxlive.termora/terminal_pty/events",
            binaryMessenger: binaryMessenger
        )
        super.init()
        methodChannel.setMethodCallHandler(handleMethodCall)
        eventChannel.setStreamHandler(self)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock()
        eventSink = events
        lock.unlock()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock()
        eventSink = nil
        lock.unlock()
        return nil
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            startSession(call.arguments, result: result)
        case "write":
            writeToSession(call.arguments, result: result)
        case "resize":
            resizeSession(call.arguments, result: result)
        case "kill":
            killSession(call.arguments, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startSession(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let executable = args["executable"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing executable", details: nil))
            return
        }

        let commandArguments = args["arguments"] as? [String] ?? []
        let workingDirectory = args["workingDirectory"] as? String
        let environment = args["environment"] as? [String: String] ?? [:]
        let columns = Int32(args["columns"] as? Int ?? 120)
        let rows = Int32(args["rows"] as? Int ?? 30)

        lock.lock()
        let sessionId = nextSessionId
        nextSessionId += 1
        lock.unlock()

        do {
            let session = try TerminalPtySession(
                id: sessionId,
                executable: executable,
                arguments: commandArguments,
                workingDirectory: workingDirectory,
                environment: environment,
                columns: columns,
                rows: rows,
                onData: { [weak self] id, data in
                    self?.sendEvent(["type": "data", "sessionId": id, "data": data])
                },
                onExit: { [weak self] id, exitCode in
                    self?.removeSession(id)
                    self?.sendEvent(["type": "exit", "sessionId": id, "exitCode": exitCode])
                }
            )
            lock.lock()
            sessions[sessionId] = session
            lock.unlock()
            session.startReading()
            result(sessionId)
        } catch {
            result(FlutterError(code: "PTY_START_FAILED", message: "\(error)", details: nil))
        }
    }

    private func writeToSession(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let sessionId = args["sessionId"] as? Int,
              let input = args["input"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing sessionId or input", details: nil))
            return
        }

        guard let session = session(for: sessionId) else {
            result(FlutterError(code: "SESSION_NOT_FOUND", message: "PTY session not found", details: nil))
            return
        }
        session.write(input)
        result(nil)
    }

    private func resizeSession(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let sessionId = args["sessionId"] as? Int else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing sessionId", details: nil))
            return
        }

        guard let session = session(for: sessionId) else {
            result(FlutterError(code: "SESSION_NOT_FOUND", message: "PTY session not found", details: nil))
            return
        }
        let columns = Int32(args["columns"] as? Int ?? 120)
        let rows = Int32(args["rows"] as? Int ?? 30)
        session.resize(columns: columns, rows: rows)
        result(nil)
    }

    private func killSession(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let sessionId = args["sessionId"] as? Int else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing sessionId", details: nil))
            return
        }

        guard let session = session(for: sessionId) else {
            result(nil)
            return
        }
        session.kill(signalName: args["signal"] as? String ?? "int")
        result(nil)
    }

    private func session(for id: Int) -> TerminalPtySession? {
        lock.lock()
        let session = sessions[id]
        lock.unlock()
        return session
    }

    private func removeSession(_ id: Int) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    private func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.lock.lock()
            let sink = self?.eventSink
            self?.lock.unlock()
            sink?(event)
        }
    }
}

private final class TerminalPtySession {
    private let id: Int
    private let pid: pid_t
    private let masterFd: Int32
    private let readQueue = DispatchQueue(label: "com.hxlive.termora.terminal_pty.read")
    private let waitQueue = DispatchQueue(label: "com.hxlive.termora.terminal_pty.wait")
    private let stateLock = NSLock()
    private var finished = false
    private var pendingOutput = Data()
    private let onData: (Int, String) -> Void
    private let onExit: (Int, Int32) -> Void

    init(
        id: Int,
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        columns: Int32,
        rows: Int32,
        onData: @escaping (Int, String) -> Void,
        onExit: @escaping (Int, Int32) -> Void
    ) throws {
        self.id = id
        self.onData = onData
        self.onExit = onExit

        var master: Int32 = -1
        var windowSize = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let childPid = forkpty(&master, nil, nil, &windowSize)
        if childPid < 0 {
            throw TerminalPtyError.spawnFailed(errno)
        }

        if childPid == 0 {
            if let workingDirectory = workingDirectory {
                _ = workingDirectory.withCString { chdir($0) }
            }
            for (key, value) in environment {
                setenv(key, value, 1)
            }
            TerminalPtySession.execChild(executable: executable, arguments: arguments)
        }

        pid = childPid
        masterFd = master
    }

    func startReading() {
        readQueue.async { [weak self] in
            self?.readLoop()
        }
        waitQueue.async { [weak self] in
            self?.waitForExit()
        }
    }

    func write(_ input: String) {
        let bytes = Array(input.utf8)
        if bytes.isEmpty { return }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(masterFd, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func resize(columns: Int32, rows: Int32) {
        var windowSize = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &windowSize)
    }

    func kill(signalName: String) {
        let signal: Int32
        switch signalName {
        case "kill":
            signal = SIGKILL
        case "term":
            signal = SIGTERM
        default:
            signal = SIGINT
        }
        Darwin.kill(pid, signal)
        if signal == SIGINT {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, !self.isFinished else { return }
                Darwin.kill(self.pid, SIGKILL)
            }
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isFinished {
            let count = Darwin.read(masterFd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(bytes: buffer, count: count)
                emitOutput(data)
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        flushPendingOutput()
    }

    private func emitOutput(_ data: Data) {
        pendingOutput.append(data)
        while !pendingOutput.isEmpty {
            if let text = String(data: pendingOutput, encoding: .utf8) {
                pendingOutput.removeAll(keepingCapacity: true)
                onData(id, text)
                return
            }

            var prefixLength = pendingOutput.count - 1
            while prefixLength > 0 {
                let prefix = pendingOutput.prefix(prefixLength)
                if let text = String(data: prefix, encoding: .utf8) {
                    pendingOutput.removeFirst(prefixLength)
                    onData(id, text)
                    break
                }
                prefixLength -= 1
            }

            if prefixLength > 0 {
                continue
            }

            if TerminalPtySession.isIncompleteUtf8Sequence(pendingOutput) {
                return
            }

            let firstByte = pendingOutput.removeFirst()
            onData(id, String(decoding: [firstByte], as: UTF8.self))
        }
    }

    private func flushPendingOutput() {
        guard !pendingOutput.isEmpty else { return }
        let text = String(decoding: pendingOutput, as: UTF8.self)
        pendingOutput.removeAll(keepingCapacity: true)
        onData(id, text)
    }

    private static func isIncompleteUtf8Sequence(_ data: Data) -> Bool {
        guard let firstByte = data.first else { return false }
        let expectedLength: Int
        if firstByte & 0b1000_0000 == 0 {
            return false
        } else if firstByte & 0b1110_0000 == 0b1100_0000 {
            expectedLength = 2
        } else if firstByte & 0b1111_0000 == 0b1110_0000 {
            expectedLength = 3
        } else if firstByte & 0b1111_1000 == 0b1111_0000 {
            expectedLength = 4
        } else {
            return false
        }
        guard data.count < expectedLength else { return false }
        for byte in data.dropFirst() {
            if byte & 0b1100_0000 != 0b1000_0000 {
                return false
            }
        }
        return true
    }

    private func waitForExit() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            break
        }
        finish(exitCode: TerminalPtySession.exitCode(from: status))
    }

    private func finish(exitCode: Int32) {
        stateLock.lock()
        if finished {
            stateLock.unlock()
            return
        }
        finished = true
        stateLock.unlock()
        Darwin.close(masterFd)
        onExit(id, exitCode)
    }

    private var isFinished: Bool {
        stateLock.lock()
        let value = finished
        stateLock.unlock()
        return value
    }

    private static func execChild(executable: String, arguments: [String]) -> Never {
        var argv = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        _ = argv.withUnsafeMutableBufferPointer { buffer in
            execv(executable, buffer.baseAddress)
        }
        for arg in argv {
            free(arg)
        }
        _exit(127)
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        let signal = status & 0x7f
        if signal != 0 {
            return 128 + signal
        }
        return status
    }
}

private enum TerminalPtyError: Error, CustomStringConvertible {
    case spawnFailed(Int32)

    var description: String {
        switch self {
        case .spawnFailed(let code):
            return "forkpty failed with errno \(code)"
        }
    }
}
