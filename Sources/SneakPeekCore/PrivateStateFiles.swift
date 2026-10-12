import Foundation
import Darwin

/// Private from the first byte, then atomically renamed into place. Directory
/// repair is opt-in so an explicit state path cannot chmod a shared project root.
public enum PrivateStateFiles {
    public static func ensureDirectory(_ directory: URL, repairExisting: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if repairExisting {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    public static func write(_ data: Data, to destination: URL, repairDirectory: Bool = false) throws {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory, repairExisting: repairDirectory)
        let temporary = directory.appendingPathComponent(".peek-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
