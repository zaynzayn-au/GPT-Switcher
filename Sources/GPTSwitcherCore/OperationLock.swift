import Darwin
import Foundation

public enum PrivateFileError: LocalizedError {
    case unsafePath
    case unsafeFile
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "账号数据路径不是安全的本地目录，已停止操作。"
        case .unsafeFile: return "账号状态文件不安全，已停止操作。"
        case .operationInProgress: return "另一个账号操作正在进行，请稍后重试。"
        }
    }
}

/// Every credential/configuration mutation and usage request holds this lock.
/// Low-level stores deliberately do not acquire it again.
public enum OperationLock {
    public final class Token: @unchecked Sendable {
        private let mutex = NSLock()
        private var descriptor: Int32?

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        public func release() {
            mutex.lock()
            defer { mutex.unlock() }
            guard let descriptor else { return }
            self.descriptor = nil
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }

        deinit { release() }
    }

    public static func acquire(paths: GPTSwitcherPaths = .live) throws -> Token {
        try paths.createSupportDirectories()
        try paths.validatePrivatePath(paths.operationLockURL)
        let descriptor = open(paths.operationLockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PrivateFileIO.posixError() }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw PrivateFileIO.posixError() }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
                throw PrivateFileError.unsafeFile
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw PrivateFileIO.posixError() }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw PrivateFileError.operationInProgress }
                throw PrivateFileIO.posixError()
            }
            return Token(descriptor: descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }
}

enum PrivateFileIO {
    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    static func rejectSymlinkComponents(root: URL, destination: URL) throws {
        var current = root.standardizedFileURL
        let suffix = destination.standardizedFileURL.path.dropFirst(current.path.count)
        var components = [current]
        for part in suffix.split(separator: "/") {
            current.appendPathComponent(String(part))
            components.append(current)
        }
        for (index, component) in components.enumerated() {
            var metadata = stat()
            if lstat(component.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw posixError()
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else { throw PrivateFileError.unsafePath }
            if index < components.count - 1 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw PrivateFileError.unsafePath }
            }
        }
    }

    static func secureDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_uid == geteuid() else { throw PrivateFileError.unsafePath }
        guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
    }

    static func read(_ url: URL, maximumSize: Int = 5_000_000) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_size > 0, metadata.st_size <= maximumSize else {
            throw PrivateFileError.unsafeFile
        }
        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumSize else { throw PrivateFileError.unsafeFile }
        return data
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".gpt-switcher-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw posixError() }
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }

    static func exists(_ url: URL) throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError()
    }
}
