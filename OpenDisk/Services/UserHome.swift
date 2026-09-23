import Foundation

// NSHomeDirectory() points at the sandbox container in the MAS build; resolve via passwd.
enum UserHome {
    static let path: String = {
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}
