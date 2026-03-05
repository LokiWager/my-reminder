import Foundation

struct AppBuildInfo {
    let version: String
    let build: String
    let buildID: String
    let commit: String
    let timestamp: String

    static var current: AppBuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info["CFBundleVersion"] as? String) ?? "0"
        let commit = (info["StandUpBuildCommit"] as? String) ?? "unknown"
        let timestamp = (info["StandUpBuildTimestamp"] as? String) ?? "unknown"
        let fallbackID = "v\(version)(\(build))-\(commit)"
        let buildID = (info["StandUpBuildID"] as? String) ?? fallbackID
        return AppBuildInfo(
            version: version,
            build: build,
            buildID: buildID,
            commit: commit,
            timestamp: timestamp
        )
    }

    var summaryLine: String {
        "Version \(version) (\(build)) · \(commit)"
    }

    var detailLine: String {
        buildID
    }
}
