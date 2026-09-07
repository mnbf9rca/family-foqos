import Foundation
@preconcurrency import SwiftData

@Model
class SavedTag {
  @Attribute(.unique) var id: String
  var kind: String
  var name: String
  @Attribute(.unique) var recordName: String
  var createdAt: Date
  var updatedAt: Date
  var syncVersion: Int

  init(id: String, kind: String, name: String, createdAt: Date = Date(), updatedAt: Date = Date(), syncVersion: Int = 0) {
    self.id = id
    self.kind = kind
    self.name = name
    self.recordName = Self.recordName(for: id)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.syncVersion = syncVersion
  }

  static func recordName(for id: String) -> String {
    "SavedTag_" + QRCodeHasher.rawHash(id)
  }

  static func fetchAll(in context: ModelContext) throws -> [SavedTag] {
    try context.fetch(FetchDescriptor<SavedTag>(sortBy: [SortDescriptor(\.name)]))
  }

  static func find(byID id: String, in context: ModelContext) throws -> SavedTag? {
    try context.fetch(FetchDescriptor<SavedTag>(predicate: #Predicate { $0.id == id })).first
  }

  static func find(byRecordName recordName: String, in context: ModelContext) throws -> SavedTag? {
    try context.fetch(FetchDescriptor<SavedTag>(predicate: #Predicate { $0.recordName == recordName })).first
  }

  /// The caller saves so migration can persist tags and profile references atomically.
  static func findOrCreate(id: String, kind: String, name: String, in context: ModelContext) throws -> SavedTag {
    if let existing = try find(byID: id, in: context) { return existing }
    let tag = SavedTag(id: id, kind: kind, name: name)
    context.insert(tag)
    return tag
  }

  static func delete(_ tag: SavedTag, in context: ModelContext) throws {
    context.delete(tag)
    try context.save()
  }

  static func summary(ids: [String], names: [String: String]) -> String {
    "\(ids.count): " + ids.map { names[$0] ?? "Removed tag" }.joined(separator: ", ")
  }

  static func assignments(profiles: [BlockedProfiles]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for profile in profiles.valid {
      let ids = Set(profile.startNFCTagIds + profile.startQRCodeIds + profile.stopNFCTagIds + profile.stopQRCodeIds)
      for id in ids { result[id, default: []].append(profile.name) }
    }
    return result
  }
}
