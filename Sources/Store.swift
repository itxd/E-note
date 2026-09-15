import Foundation

// MARK: - JSON 持久化(原子写:临时文件 + fsync + rename)

enum NoteStoreIO {
    static private(set) var loadFailed = false
    static func load() -> [NoteRecord] {
        guard FileManager.default.fileExists(atPath: AppPaths.notesFile.path) else { return [] }
        guard let data = try? Data(contentsOf: AppPaths.notesFile) else { loadFailed = true; return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notes = try? decoder.decode([NoteRecord].self, from: data) else { loadFailed = true; return [] }
        return notes
    }

    @discardableResult
    static func save(_ notes: [NoteRecord]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return false }
        return atomicWrite(data, to: AppPaths.notesFile)
    }

    @discardableResult
    static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".enote-" + UUID().uuidString)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlink(tmp.path) }
        let written = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < ptr.count {
                let n = write(fd, base.advanced(by: offset), ptr.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        guard written, fsync(fd) == 0 else { return false }
        return rename(tmp.path, url.path) == 0
    }
}
