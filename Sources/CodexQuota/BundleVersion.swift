import Foundation

struct BundleVersion: Equatable, Comparable {
    let shortVersion: String
    let buildVersion: String

    init(shortVersion: String, buildVersion: String) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }

    init(infoDictionary: [String: Any]) {
        self.shortVersion = infoDictionary["CFBundleShortVersionString"] as? String ?? ""
        self.buildVersion = infoDictionary["CFBundleVersion"] as? String ?? ""
    }

    static var current: BundleVersion {
        BundleVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    var displayString: String {
        buildVersion.isEmpty || buildVersion == shortVersion ? shortVersion : "\(shortVersion) (\(buildVersion))"
    }

    func compare(to other: BundleVersion) -> ComparisonResult {
        let short = shortVersion.compare(other.shortVersion, options: .numeric)
        if short != .orderedSame { return short }
        return buildVersion.compare(other.buildVersion, options: .numeric)
    }

    static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        lhs.compare(to: rhs) == .orderedAscending
    }
}
