import Foundation
import Darwin

public enum FileAccessError: Error, Equatable {
    case unavailable, placeholder, notRegular, materializationPolicyUnavailable
}

/// Restore the thread policy before returning to the executor. Never hold a
/// thread-local policy across an await (a task may resume on another thread).
public func withoutFileMaterialization<T>(_ body: () throws -> T) throws -> T {
    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    guard previous >= 0,
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                        IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
        throw FileAccessError.materializationPolicyUnavailable
    }
    defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
    return try body()
}

public struct LocalFileMetadata: Sendable {
    public let size: Int64
    public let modificationDate: Date
    public let identity: String
    public let isDirectory: Bool
    public let isRegular: Bool
    public let isSymbolicLink: Bool
    public let isDataless: Bool

    public init(size: Int64, modificationDate: Date, identity: String, isDirectory: Bool = false,
                isRegular: Bool = true, isSymbolicLink: Bool = false, isDataless: Bool = false) {
        self.size = size; self.modificationDate = modificationDate; self.identity = identity
        self.isDirectory = isDirectory; self.isRegular = isRegular
        self.isSymbolicLink = isSymbolicLink; self.isDataless = isDataless
    }
}

public protocol FileMetadataProviding: Sendable {
    func metadata(for url: URL) throws -> LocalFileMetadata
}

public struct LocalFileMetadataProvider: FileMetadataProviding {
    public init() {}
    public func metadata(for url: URL) throws -> LocalFileMetadata {
        try withoutFileMaterialization {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &info) } ?? -1
            }
            guard result == 0 else { throw FileAccessError.unavailable }
            return LocalFileMetadata(size: Int64(info.st_size),
                modificationDate: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                                       + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                identity: "\(info.st_dev):\(info.st_ino)",
                isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                isRegular: (info.st_mode & S_IFMT) == S_IFREG,
                isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK,
                isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0)
        }
    }
}

public struct CoordinatedFileAccess: Sendable {
    private let metadata: any FileMetadataProviding
    public init(metadata: any FileMetadataProviding = LocalFileMetadataProvider()) { self.metadata = metadata }

    /// Pin a materialized file without reading its contents first. File Provider
    /// cannot evict an open file. Then perform the synchronous parser within a
    /// full coordinated read, with materialization disabled on this thread.
    public func read<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try withoutFileMaterialization {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var descriptor: Int32 = -1
            var pinned: LocalFileMetadata?
            var pinError: (any Error)?
            coordinator.coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly,
                                   error: &coordinationError) { coordinatedURL in
                do {
                    let info = try metadata.metadata(for: coordinatedURL)
                    guard info.isRegular, !info.isSymbolicLink else { throw FileAccessError.notRegular }
                    guard !info.isDataless else { throw FileAccessError.placeholder }
                    descriptor = coordinatedURL.withUnsafeFileSystemRepresentation { path in
                        path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
                    }
                    guard descriptor >= 0 else { throw FileAccessError.unavailable }
                    var opened = stat()
                    guard fstat(descriptor, &opened) == 0 else { throw FileAccessError.unavailable }
                    guard (opened.st_flags & UInt32(SF_DATALESS)) == 0 else { throw FileAccessError.placeholder }
                    guard "\(opened.st_dev):\(opened.st_ino)" == info.identity else { throw ExtractionError.changedDuringRead }
                    pinned = info
                } catch { pinError = error }
            }
            defer { if descriptor >= 0 { _ = close(descriptor) } }
            if let pinError { throw pinError }
            guard coordinationError == nil, let pinned else { throw FileAccessError.unavailable }
            var result: Result<T, any Error>?
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges,
                                   error: &coordinationError) { coordinatedURL in
                result = Result {
                    let before = try metadata.metadata(for: coordinatedURL)
                    guard !before.isDataless else { throw FileAccessError.placeholder }
                    guard before.identity == pinned.identity else { throw ExtractionError.changedDuringRead }
                    let value = try body(coordinatedURL)
                    let after = try metadata.metadata(for: coordinatedURL)
                    guard after.identity == before.identity, after.size == before.size,
                          after.modificationDate == before.modificationDate else { throw ExtractionError.changedDuringRead }
                    return value
                }
            }
            guard coordinationError == nil, let result else { throw FileAccessError.unavailable }
            return try result.get()
        }
    }
}

/// Only ENOENT certifies a rename. Permission failures must retain the old entry.
public func localPathIsMissing(_ url: URL) -> Bool {
    (try? withoutFileMaterialization {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }) ?? false
}
