//  PhotoLibrary.swift
//  photocap — safe, read-only parser for a Photos Library package.
//
//  IMPORTANT: This module never mutates the library. It reads the SQLite
//  metadata (Photos.sqlite) for reporting and measures folder sizes via `du`
//  (robust even over the live multi-GB Photos.sqlite). Deletions happen in
//  Pruner.swift, only on rebuildable cache folders.

import Foundation
import SQLite3

public struct CategorySize {
    public let name: String
    public let bytes: UInt64
    public let rebuildable: Bool   // true => Photos regenerates this automatically
    public let safeToPrune: Bool
}

public struct CloudItem: Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let filename: String
    public let bytes: UInt64          // local full-resolution size on disk
    public let date: Date?
    public let isFavorite: Bool
}

public final class PhotoLibrary: @unchecked Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Total package size in bytes (via `du` — handles the live multi-GB sqlite).
    public var totalSizeBytes: UInt64 {
        duBytes(at: url.path)
    }

    /// Sizes of the well-known library subdirectories, tagged with pruning safety.
    public func categorySizes() -> [CategorySize] {
        let groups: [(path: String, name: String, rebuildable: Bool, safe: Bool)] = [
            ("database/search/Spotlight", "Spotlight index", true, true),
            ("resources/derivatives",     "Derivative caches", true, true),
            ("database",                  "Metadata (Photos.sqlite)", false, false),
            ("resources",                 "Resources (cpl/journals/caches)", false, false),
            ("private",                   "Private", false, false),
            ("scopes",                    "Scopes", false, false),
            ("originals",                 "Originals (local full-res)", false, false),
            ("internal",                  "Internal", false, false),
        ]
        return groups.map { g in
            let p = url.appendingPathComponent(g.path).path
            let b = duBytes(at: p)
            return CategorySize(name: g.name, bytes: b, rebuildable: g.rebuildable, safeToPrune: g.safe)
        }
    }

    /// Read cloud-downloaded originals from Photos.sqlite metadata.
    /// Surfaces the assets that currently occupy LOCAL disk space (i.e. have a
    /// file in `originals/`), sorted largest-first — these are what "cap" can act on.
    public func cloudDownloadedItems(limit: Int = 50) -> [CloudItem] {
        var items: [CloudItem] = []
        let dbPath = url.appendingPathComponent("database/Photos.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return items
        }
        defer { sqlite3_close(db) }

        // ZASSET holds media items. We want ZUUID, ZFILENAME, ZADDEDDATE, ZFAVORITE.
        // Order newest-first so the tool surfaces recently-downloaded heavy items.
        let q = """
        SELECT ZUUID, ZFILENAME, ZADDEDDATE, ZFAVORITE
        FROM ZASSET
        WHERE ZTRASHEDSTATE = 0
        ORDER BY ZADDEDDATE DESC
        LIMIT \(max(limit, 1) * 4)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return items }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidPtr = sqlite3_column_text(stmt, 0) else { continue }
            let uuid = String(cString: uuidPtr)
            var filename = ""
            if let f = sqlite3_column_text(stmt, 1) { filename = String(cString: f) }
            let appleTime = sqlite3_column_double(stmt, 2)
            let favorite = sqlite3_column_int(stmt, 3) != 0
            let date = Date(timeIntervalSinceReferenceDate: appleTime)
            let bytes = localSize(forUUID: uuid)
            guard bytes > 0 else { continue }   // only items physically on disk
            items.append(CloudItem(uuid: uuid, filename: filename, bytes: bytes, date: date, isFavorite: favorite))
            if items.count >= max(limit, 1) { break }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Approximate on-disk size of a given asset UUID by summing matching files.
    /// Originals live at: originals/<firstHexChar>/<FULL_UUID>.<ext>  (and a
    /// possible <FULL_UUID>_<n>.mov sidecar). We also check resources/ for
    /// any derived files keyed by the same UUID.
    private func localSize(forUUID uuid: String) -> UInt64 {
        let first = String(uuid.prefix(1)).uppercased()
        let roots = [
            url.appendingPathComponent("originals/\(first)"),
            url.appendingPathComponent("resources"),
        ]
        var total: UInt64 = 0
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            // Bounded: list immediate children, then du any whose name begins with the UUID.
            if let ents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for e in ents where e.lastPathComponent.hasPrefix(uuid) {
                    total += duBytes(at: e.path)
                }
            }
        }
        return total
    }

    // MARK: - filesystem helpers (all via `du` for robustness)

    public func sizeOfDirectory(at url: URL) -> UInt64 { duBytes(at: url.path) }

    /// Kilobytes from `du -sk`, converted to bytes.
    private func duBytes(at path: String) -> UInt64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let out = ProcessRunner.run("/usr/bin/du", ["-sk", path])
        // du prints "<kb>\t<path>"
        let first = out.split(separator: "\t").first ?? ""
        if let kb = UInt64(first) {
            return kb * 1024
        }
        return 0
    }
}

public func formatBytes(_ b: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(b))
}

/// Left-pad/truncate a string to a fixed width for aligned CLI output.
public func pad(_ s: String, _ n: Int) -> String {
    let t = s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    return t
}

/// Minimal process runner (no external deps).
/// stderr is routed to a writable /dev/null handle: an undrained stderr Pipe
/// makes children like `ps`/`pgrep` block once the buffer fills, hanging
/// waitUntilExit forever. FileHandle.nullDevice is a *read* handle and cannot
/// be used as a write destination, so we open /dev/null for writing.
public enum ProcessRunner {
    public static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run a child with stdout/stderr inherited from the parent, for
    /// long-running commands (e.g. a multi-hundred-GB `ditto`) whose output
    /// should stream to the terminal instead of being buffered. Returns the
    /// exit status, or -1 if the process could not be launched.
    public static func runStreaming(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
