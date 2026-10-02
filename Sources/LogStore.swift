import Foundation

/// 文件 + 内存环 buffer 双写日志。线程安全。
final class LogStore {
    private let lock = NSLock()
    private var ring: [String] = []
    private let maxRing = 200
    private let maxFileSize: UInt64 = 5 * 1024 * 1024

    let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        fileURL = base
            .appendingPathComponent("Logs/com.xenori.dshdock", isDirectory: true)
            .appendingPathComponent("dsh.log")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func append(_ s: String) {
        let line: String
        lock.lock()
        // 按行切分存环
        let parts = s.components(separatedBy: "\n")
        for p in parts {
            // 保留空行语义但避免 ring 被超长行打爆
            let t = p.count > 4000 ? String(p.prefix(4000)) + "…(truncated)" : p
            ring.append(t)
            if ring.count > maxRing { ring.removeFirst(ring.count - maxRing) }
        }
        line = s.hasSuffix("\n") ? s : s + "\n"
        lock.unlock()
        writeToFile(line)
    }

    func header(_ s: String) {
        append("===== \(s) =====")
    }

    func tail(_ n: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return ring.suffix(n).joined(separator: "\n")
    }

    func clearRing() {
        lock.lock()
        ring.removeAll()
        lock.unlock()
    }

    private func writeToFile(_ s: String) {
        rotateIfNeeded()
        guard let data = s.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(data)
                h.closeFile()
            }
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64, size > maxFileSize else { return }
        let bak = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: fileURL, to: bak)
    }
}
