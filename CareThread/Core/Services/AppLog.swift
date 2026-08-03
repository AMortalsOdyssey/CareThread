import OSLog

enum AppLog {
    private static let subsystem = "io.8xd.carethread"
    static let data = Logger(subsystem: subsystem, category: "data")
    static let vault = Logger(subsystem: subsystem, category: "vault")
    static let extraction = Logger(subsystem: subsystem, category: "extraction")
    static let userAction = Logger(subsystem: subsystem, category: "user-action")
}
