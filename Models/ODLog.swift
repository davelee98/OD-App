import Foundation
import os

/// Central `os.Logger` registry for the app. Categories map to subsystems of the codebase so
/// Console.app / `log stream` can be filtered per concern. The subsystem matches
/// `PRODUCT_BUNDLE_IDENTIFIER` so device logs group under the app in Console.
enum ODLog {
    static let subsystem = "org.opendisplay.od-app"

    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let proto = Logger(subsystem: subsystem, category: "protocol")
    static let toolbox = Logger(subsystem: subsystem, category: "toolbox")
    static let imaging = Logger(subsystem: subsystem, category: "imaging")
    static let auth = Logger(subsystem: subsystem, category: "auth")
}

extension OSLogType {
    /// `OSLogType` has no dedicated warning level (only default/info/debug/error/fault).
    /// Surface warnings at the persisted `.default` (notice) level so deferred/recovered
    /// states stand out from routine `.info`/`.debug` without polluting the `.error` stream.
    static let warning: OSLogType = .default
}
