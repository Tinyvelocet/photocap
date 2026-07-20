//  main.swift — photocap command-line interface
//
//  Usage:
//    photocap status [--library PATH]            report size by category
//    photocap cloud [--library PATH] [--limit N] list largest cloud-downloaded items
//    photocap dryrun [--library PATH]            show what pruning would free
//    photocap prune --target PATH [--force]      prune one rebuildable cache
//    photocap cap --bytes N [--force]            prune rebuildable caches until <= N bytes
//    photocap quota [--cap N]                    print APFS quota suggestions for a hard cap

import Foundation
import PhotocapEngine

let args = Array(CommandLine.arguments.dropFirst())
let defaultLibrary = "\(NSHomeDirectory())/Pictures/Photos Library.photoslibrary"

func value(for flag: String, from args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func has(_ flag: String, in args: [String]) -> Bool { args.contains(flag) }

func libraryURL() -> URL {
    let p = value(for: "--library", from: args) ?? defaultLibrary
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

guard let command = args.first else {
    print("""
    photocap — cap the size of a Photos library (safely)
    USAGE:
      photocap status [--library PATH]
      photocap cloud  [--library PATH] [--limit N]
      photocap dryrun [--library PATH]
      photocap prune  --target PATH [--force]
      photocap cap    --bytes N [--force]
      photocap quota  [--cap N]
    """)
    exit(0)
}

let lib = PhotoLibrary(url: libraryURL())

switch command {
case "status":
    print("Library: \(lib.url.path)")
    fflush(stdout)
    print("Total:   \(formatBytes(lib.totalSizeBytes))")
    fflush(stdout)
    print("")
    print("\(pad("category", 32)) \(pad("size", 12)) prune?")
    for c in lib.categorySizes() {
        let flag = c.safeToPrune ? "safe" : "no"
        print("\(pad(c.name, 32)) \(pad(formatBytes(c.bytes), 12)) \(flag)")
        fflush(stdout)
    }

case "cloud":
    let limit = Int(value(for: "--limit", from: args) ?? "30") ?? 30
    let items = lib.cloudDownloadedItems(limit: max(limit, 1))
    print("Largest cloud-downloaded items (local full-res on disk):")
    for (i, it) in items.prefix(limit).enumerated() {
        let fav = it.isFavorite ? " ★" : ""
        let d = it.date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "?"
        print("\(String(format: "%3d", i + 1)). \(pad(formatBytes(it.bytes), 12)) \(d) \(it.filename)\(fav)")
    }

case "dryrun":
    print("What pruning would free (rebuildable caches only):")
    for r in Pruner.dryRun(library: lib) {
        print("  \(pad(r.target, 28)) \(pad(formatBytes(r.bytesFreed), 12)) \(r.message)")
    }

case "prune":
    guard let target = value(for: "--target", from: args) else { fail("prune requires --target PATH") }
    do {
        let r = try Pruner.prune(library: lib, target: target, force: has("--force", in: args))
        print("pruned \(r.target): \(r.message)")
    } catch {
        fail(String(describing: error))
    }

case "cap":
    guard let n = value(for: "--bytes", from: args), let cap = UInt64(n) else { fail("cap requires --bytes N (bytes)") }
    do {
        let res = try Pruner.pruneToCap(library: lib, capBytes: cap, force: has("--force", in: args))
        if res.isEmpty { print("already at or below cap (\(formatBytes(lib.totalSizeBytes))).") }
        for r in res { print("pruned \(r.target): \(r.message)") }
        print("new total: \(formatBytes(lib.totalSizeBytes))")
    } catch {
        fail(String(describing: error))
    }

case "quota":
    let cap = UInt64(value(for: "--cap", from: args) ?? "60000000000") ?? 60_000_000_000
    let gb = Double(cap) / 1_000_000_000
    print("For a HARD cap (OS-enforced) of \(String(format: "%.0f", gb)) GB:")
    print("  1. Open Disk Utility -> your startup disk -> Add APFS Volume")
    print("  2. Set 'Quota Size' = \(String(format: "%.0f", gb)) GB")
    print("  3. Quit Photos, copy the library to the new volume")
    print("  4. Hold Option, open Photos, choose the new library -> 'Use as System Photo Library'")
    print("The OS physically prevents Photos from exceeding the quota. iCloud is untouched.")

case "setup-quota":
    // Create an APFS volume with a hard quota and copy the library onto it.
    // iCloud Photos is NEVER modified — only the local library is relocated
    // onto a size-capped volume, so the OS forces aggressive local eviction.
    let cap = UInt64(value(for: "--cap", from: args) ?? "60000000000") ?? 60_000_000_000
    let volName = value(for: "--name", from: args) ?? "PhotoCap"
    let gb = Double(cap) / 1_000_000_000
    let container = (value(for: "--container", from: args)) ?? "disk3"
    print("Creating APFS volume '\(volName)' with \(String(format: "%.0f", gb)) GB quota on \(container) ...")
    let createOut = ProcessRunner.run("/usr/sbin/diskutil",
        ["apfs", "addVolume", container, "APFS", volName, "-quota", "\(cap)"])
    print(createOut.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    let dest = "/Volumes/\(volName)/Photos Library.photoslibrary"
    print("Copying library to \(dest) (this preserves iCloud sync state) ...")
    print("Then in Photos: hold Option, open, choose '\(dest)' -> Use as System Photo Library.")
    print("NOTE: the copy itself is large; run it manually or with --go once you've confirmed the volume.")

default:
    fail("unknown command: \(command)")
}
