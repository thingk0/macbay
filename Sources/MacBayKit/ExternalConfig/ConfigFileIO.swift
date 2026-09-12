import Darwin
import Foundation

enum ConfigFileRead {
    case success(data: Data, truncated: Bool)
    case failure(String)
}

enum ConfigFileIO {
    static func identity(at path: String, follow: Bool) -> FileIdentity? {
        var info = stat()
        let result = follow ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func isDirectory(at path: String, fileManager: FileManager, follow: Bool) -> Bool {
        if !follow, (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
            return false
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isSymbolicLink(at path: String, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    static func readLimited(
        at url: URL,
        fileManager: FileManager,
        maxBytes: Int
    ) -> ConfigFileRead {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            return .failure("the file could not be read: \(error.localizedDescription)")
        }

        // Open without waiting for a FIFO writer, then validate the opened object
        // so a path replacement between discovery and reading is also covered.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure("the file could not be read")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return .failure("the path is not a regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            while data.count < maxBytes {
                let chunkSize = min(64 * 1024, maxBytes - data.count)
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            let extra = try handle.read(upToCount: 1) ?? Data()
            return .success(data: data, truncated: !extra.isEmpty)
        } catch {
            return .failure("the file could not be read: \(error.localizedDescription)")
        }
    }
}
