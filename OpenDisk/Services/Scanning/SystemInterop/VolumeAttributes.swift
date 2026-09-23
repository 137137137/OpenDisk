import Darwin
import Foundation

enum VolumeAttributes {

    private static let attrVolInfo: UInt32 = 0x8000_0000
    private static let attrVolCapabilities: UInt32 = 0x0002_0000
    private static let volCapIntSearchFS: UInt32 = 0x0000_0001

    private struct VolCapabilitiesReply {
        var length: UInt32 = 0
        var capabilities: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var valid: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    }

    static func supportsCatalogSearch(atPath path: String) -> Bool {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrVolInfo | attrVolCapabilities

        var reply = VolCapabilitiesReply()
        let status = withUnsafeMutableBytes(of: &reply) { replyBytes in
            getattrlist(path, &request, replyBytes.baseAddress!, replyBytes.count, 0)
        }
        guard status == 0, reply.length <= UInt32(MemoryLayout<VolCapabilitiesReply>.size) else {
            return false
        }
        return (reply.valid.1 & volCapIntSearchFS) != 0
            && (reply.capabilities.1 & volCapIntSearchFS) != 0
    }

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
