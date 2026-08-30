import Foundation

/// Frames a pipe's bytes into UTF-8 lines using `readabilityHandler`
/// (dispatch threads), never the Swift cooperative pool — `FileHandle.bytes`
/// performs blocking `read(2)` on cooperative threads and can starve the
/// entire task pool behind one long-lived child (observed in practice; see
/// ProcessCoreTests history).
///
/// NDJSON lines from `claude` can be multi-MB; the framer splits on `\n` at
/// the byte level so a line is only decoded once it is complete.
final class PipeLineReader: @unchecked Sendable {
    // `buffer` is only touched inside readabilityHandler invocations, which
    // the handle serializes; `@unchecked Sendable` is confined to that
    // invariant (documented exception per spec 02 §11.6).
    private var buffer = Data()
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let onEOF: @Sendable () -> Void

    init(handle: FileHandle,
         onLine: @escaping @Sendable (String) -> Void,
         onEOF: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.onLine = onLine
        self.onEOF = onEOF
        handle.readabilityHandler = { [weak self] fileHandle in
            self?.drain(fileHandle)
        }
    }

    private func drain(_ fileHandle: FileHandle) {
        let chunk = fileHandle.availableData
        guard !chunk.isEmpty else {
            // EOF: flush any unterminated final line, then stop.
            if !buffer.isEmpty {
                emit(buffer)
                buffer.removeAll()
            }
            fileHandle.readabilityHandler = nil
            onEOF()
            return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            emit(lineData)
        }
    }

    private func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        let line = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        onLine(line)
    }

    func cancel() {
        handle.readabilityHandler = nil
    }
}
