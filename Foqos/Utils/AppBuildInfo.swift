import Foundation

struct AppBuildInfo {
  private let infoDictionary: [String: Any]

  init(infoDictionary: [String: Any] = Self.bundleInfoDictionary()) {
    self.infoDictionary = infoDictionary
  }

  private static func bundleInfoDictionary(bundle: Bundle = .main) -> [String: Any] {
    var info = bundle.infoDictionary ?? [:]
    guard let url = bundle.url(forResource: "BuildInfo", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let buildInfo = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      return info
    }
    info.merge(buildInfo) { _, buildValue in buildValue }
    return info
  }

  var version: String {
    infoDictionary["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  var build: String {
    infoDictionary["CFBundleVersion"] as? String ?? "Unknown"
  }

  var commitDisplay: String {
    guard let sha = infoDictionary["GitCommitSHA"] as? String,
      !sha.isEmpty,
      sha != "unknown"
    else {
      return "unknown"
    }

    let dirty = (infoDictionary["GitHasUncommittedChanges"] as? String) == "YES"
    return dirty ? "\(sha)+wip" : sha
  }
}
