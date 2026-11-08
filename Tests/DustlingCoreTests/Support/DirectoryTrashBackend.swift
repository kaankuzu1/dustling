import Foundation
@testable import DustlingCore

/// Test stand-in for the Trash: moves items into `directory`, naming collisions like Finder
/// (`Caches`, `Caches 2`; `a.log`, `a 2.log`).
struct DirectoryTrashBackend: TrashBackend {
    let directory: URL

    func trash(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        var target = directory.appending(path: url.lastPathComponent)
        while (try? fm.attributesOfItem(atPath: target.path(percentEncoded: false))) != nil {
            n += 1
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            target = directory.appending(path: name)
        }
        try fm.moveItem(at: url, to: target)
        return target
    }
}
