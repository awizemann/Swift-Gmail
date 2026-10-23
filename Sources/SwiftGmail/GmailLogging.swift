//
//  GmailLogging.swift
//  SwiftGmail
//
//  The `os.Logger` subsystem every logger in this package uses. A host app
//  that filters or exports its unified log by subsystem sets this ONCE at
//  startup, before the first client or bucket is created; the default is
//  the package name.
//

import Foundation
import os

public enum GmailLogging {
    /// Set once at startup, before any `GmailAPIClient` or
    /// `GmailQuotaBucket` exists. Not synchronised: a later write races the
    /// `static let` loggers that already captured the previous value.
    nonisolated(unsafe) public static var subsystem: String = "SwiftGmail"

    static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
