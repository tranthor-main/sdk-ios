import Foundation

/// The OS notification permission reported with `Installation Registered`.
package enum InstallationPermission: String, Sendable, Equatable {
    case granted, denied
    /// Not determined or not readable. The server treats the installation as reachable.
    case unknown
}

/// The APNs service the token belongs to: the signed `aps-environment` entitlement.
package enum InstallationEnvironment: String, Sendable, Equatable { case development, production }
