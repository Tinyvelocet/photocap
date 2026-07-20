//  Pruner.swift
//  photocap — pruning engine. ONLY ever deletes rebuildable cache folders:
//  the Spotlight index and the derivative caches. Never touches originals,
//  the metadata DB, or anything else.

import Foundation

public struct PruneResult {
    public let target: String
    public let bytesFreed: UInt64
    public let ok: Bool
    public let message: String
}

public enum PrunerError: Error, CustomStringConvertible {
    case libraryInUse        // photolibraryd / photoanalysisd running
    case notRebuildable(String)
    case removalFailed(String)

    public var description: String {
        switch self {
        case .libraryInUse:
            return "Photos background daemons are running. Quit Photos.app and stop photolibraryd/photoanalysisd first."
        case .notRebuildable(let p):
            return "Refusing to delete non-rebuildable path: \(p)"
        case .removalFailed(let m):
            return "Removal failed: \(m)"
        }
    }
}

public struct Pruner {
    /// The only paths the tool is permitted to delete. Anything else is rejected.
    public static let allowedTargets: [String] = [
        "database/search/Spotlight",
        "resources/derivatives",
    ]

    /// True if a Photos daemon currently holds the library.
    public static func libraryInUse() -> Bool {
        // Lightweight, timeout-guarded check via pgrep (avoids `ps` deadlocks).
        let names = ["photolibraryd", "photoanalysisd", "cloudphotosd"]
        for n in names {
            let out = ProcessRunner.run("/usr/bin/pgrep", ["-x", n])
            if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// Simulate (dry-run) by reporting how much each allowed target would free.
    public static func dryRun(library: PhotoLibrary) -> [PruneResult] {
        allowedTargets.map { t in
            let p = library.url.appendingPathComponent(t).path
            let u = URL(fileURLWithPath: p)
            let bytes = library.sizeOfDirectory(at: u)
            return PruneResult(target: t, bytesFreed: bytes, ok: true,
                               message: bytes > 0 ? "would free \(formatBytes(bytes))" : "already empty")
        }
    }

    /// Actually prune the named allowed target. `target` is the library-relative path.
    public static func prune(library: PhotoLibrary, target: String, force: Bool = false) throws -> PruneResult {
        guard allowedTargets.contains(target) else {
            throw PrunerError.notRebuildable(target)
        }
        if !force {
            guard !libraryInUse() else { throw PrunerError.libraryInUse }
        }
        let u = library.url.appendingPathComponent(target)
        let bytesBefore = library.sizeOfDirectory(at: u)
        guard FileManager.default.fileExists(atPath: u.path) else {
            return PruneResult(target: target, bytesFreed: 0, ok: true, message: "already removed")
        }
        do {
            try FileManager.default.removeItem(at: u)
        } catch {
            throw PrunerError.removalFailed(error.localizedDescription)
        }
        return PruneResult(target: target, bytesFreed: bytesBefore, ok: true,
                           message: "freed \(formatBytes(bytesBefore))")
    }

    /// Prune everything allowed, down to at most `capBytes` total library size.
    /// Returns the results of each removal performed.
    public static func pruneToCap(library: PhotoLibrary, capBytes: UInt64, force: Bool = false) throws -> [PruneResult] {
        guard force || !libraryInUse() else { throw PrunerError.libraryInUse }
        var results: [PruneResult] = []
        // Visit each allowed target at most once. The two rebuildable caches are
        // the only things we can remove, so a single pass suffices; we stop early
        // once we're under the cap.
        var current = library.totalSizeBytes
        for target in allowedTargets {
            guard current > capBytes else { break }
            let r = try prune(library: library, target: target, force: force)
            if r.bytesFreed > 0 { results.append(r) }
            current = library.totalSizeBytes
        }
        return results
    }
}
