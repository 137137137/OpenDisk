import Darwin
import Foundation

enum VolumeAttributes {
    static func filesystemType(ofVolumeContaining path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_fstypename) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func mountPoint(ofVolumeContaining path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func isVolumeRoot(_ path: String) -> Bool {
        mountPoint(ofVolumeContaining: path) == path
    }

    static func deviceID(ofPath path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
