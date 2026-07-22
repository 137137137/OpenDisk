import Darwin
import Foundation

/// Queries volume-level facts the scan engine needs: whether a volume
/// supports `searchfs`, where a path's volume is mounted, and how many
/// bytes are in use.
enum VolumeAttributes {

    private static let attrVolInfo: UInt32 = 0x8000_0000
    private static let attrVolCapabilities: UInt32 = 0x0002_0000
    private static let volCapIntSearchFS: UInt32 = 0x0000_0001

    /// Mirrors the getattrlist reply for `ATTR_VOL_CAPABILITIES`:
    /// a length word followed by `vol_capabilities_attr_t`
    /// (two `u_int32_t[4]` sets: capabilities, then valid).
    private struct VolCapabilitiesReply {
        var length: UInt32 = 0
        var capabilities: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var valid: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    }

    /// True when the volume containing `path` implements `searchfs(2)`.
    ///
    /// Both the `valid` and `capabilities` bits of
    /// `VOL_CAPABILITIES_INTERFACES` must advertise `VOL_CAP_INT_SEARCHFS`.
    /// APFS and HFS+ do; SMB, NFS, exFAT and FAT do not.
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
        // Interfaces set is index 1 of the four-word capability sets.
        return (reply.valid.1 & volCapIntSearchFS) != 0
            && (reply.capabilities.1 & volCapIntSearchFS) != 0
    }

    /// The filesystem type name ("apfs", "hfs", "exfat", ...) of the
    /// volume containing `path`, or nil on failure.
    static func filesystemType(ofVolumeContaining path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_fstypename) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// The mount point of the volume containing `path`, or nil on failure.
    static func mountPoint(ofVolumeContaining path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// True when `path` is itself the mount point of a volume.
    static func isVolumeRoot(_ path: String) -> Bool {
        mountPoint(ofVolumeContaining: path) == path
    }

    /// The device ID (`st_dev`) of `path`, or nil if it cannot be stat'ed.
    static func deviceID(ofPath path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
