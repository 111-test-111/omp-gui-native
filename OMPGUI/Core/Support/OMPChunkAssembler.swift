import Foundation

/// Runs on the stdio reader, before delivery to the main actor. OMP sends one
/// contiguous sequence per logical frame; unrelated non-chunk events may pass
/// through, but a second sequence must never replace an unfinished one.
struct OMPChunkAssembler {
    private struct Frame {
        var id: String
        var count: Int
        var size: Int
        var next = 0
        var data = Data()
    }
    private var frame: Frame?

    enum FrameError: LocalizedError {
        case invalid
        var errorDescription: String? { AppText.localized("OMP sent an invalid chunked RPC frame.") }
    }

    mutating func append(_ value: JSONValue) throws -> (value: JSONValue, byteCount: Int?)? {
        guard value["type"]?.string == "rpc_chunk" else { return (value, nil) }
        guard let id = value["chunkId"]?.string, !id.isEmpty, id.utf8.count <= 256,
              let index = value["index"]?.int, index >= 0,
              let count = value["count"]?.int, count > 0, count <= 1_024, index < count,
              let size = value["byteLength"]?.int, size > 0, size <= 64 * 1_024 * 1_024,
              let encoded = value["data"]?.string,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { throw FrameError.invalid }
        if index == 0 {
            guard frame == nil else { throw FrameError.invalid }
            frame = Frame(id: id, count: count, size: size)
        }
        guard frame?.id == id, frame?.next == index, frame?.count == count,
              frame?.size == size, let length = frame?.data.count,
              length <= size - bytes.count else { throw FrameError.invalid }
        // Mutate the retained buffer directly: copying Frame before append causes
        // Data to copy all preceding chunks on every iteration.
        frame?.data.append(bytes)
        frame?.next += 1
        guard index + 1 == count else { return nil }
        let span = RuntimeMetrics.begin(.rpcReassembly)
        defer { RuntimeMetrics.end(span); frame = nil }
        guard let completed = frame, completed.data.count == size,
              let decoded = JSONValue.parse(completed.data),
              decoded.object != nil, decoded["type"]?.string != "rpc_chunk" else { throw FrameError.invalid }
        return (decoded, completed.size)
    }
}
