import Foundation

public enum InstallLocationPolicy {
    public static func shouldOfferMove(
        bundlePath: String,
        homeDirectory: String,
        sourceRootHasBuildScript: Bool
    ) -> Bool {
        if sourceRootHasBuildScript { return false }

        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let userApplications = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL.path

        return !path.hasPrefix(userApplications + "/") &&
            !path.hasPrefix(systemApplications + "/")
    }
}
