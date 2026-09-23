import Foundation

enum UserHome {
    static let path: String = {
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}
