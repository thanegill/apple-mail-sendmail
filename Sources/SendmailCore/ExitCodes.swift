import Foundation

public enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case dataErr = 65
    case noUser = 67
    case osErr = 71
    case tempFail = 75
    case config = 78
}

public func warn(_ msg: String) {
    FileHandle.standardError.write(Data("sendmail: \(msg)\n".utf8))
}

public func die(_ msg: String, code: ExitCode) -> Never {
    warn(msg)
    exit(code.rawValue)
}
