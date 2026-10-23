//
//  GmailLogging.swift
//  SwiftGmail
//
//  The `os.Logger` subsystem every logger in this package uses. A host app
//  that filters or exports its unified log by subsystem configures it ONCE
//  at launch, before the first client or quota bucket exists; the default is
//  the package name.
//

import Foundation
import os

public enum GmailLogging {
    private struct State {
        var subsystem = "SwiftGmail"
        /// Set the first time a logger is created. After that the subsystem
        /// is fixed: the loggers already built would otherwise disagree
        /// with the ones built later.
        var sealed = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// The subsystem in force (the default until `configure` runs).
    public static var subsystem: String { state.withLock { $0.subsystem } }

    /// Call once at launch, before any SwiftGmail type logs. A call after
    /// the first logger exists is ignored and reported as a fault, because
    /// honouring it would split the package's log across two subsystems.
    public static func configure(subsystem: String) {
        let accepted = state.withLock { s -> Bool in
            guard !s.sealed else { return false }
            s.subsystem = subsystem
            return true
        }
        if !accepted {
            Logger(subsystem: self.subsystem, category: "GmailLogging")
                .fault("configure(subsystem:) called after the first SwiftGmail logger was created — ignored")
        }
    }

    static func logger(category: String) -> Logger {
        let subsystem = state.withLock { s -> String in
            s.sealed = true
            return s.subsystem
        }
        return Logger(subsystem: subsystem, category: category)
    }
}
