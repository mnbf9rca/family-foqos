import Foundation
import XCTest

final class CloudKitCodeSchemaDriftTests: XCTestCase {
  func testGivenEverySupportedPattern_WhenValidating_ThenDiscoversLiteralWireKeys() throws {
    let root = try makeFixtureRoot(
      sources: [
        "CloudKit/FieldRecord.swift": """
        struct FieldRecord {
          static let recordType = "FieldRecord"
          enum FieldKey: String {
            case implicitName
            case swiftName = "wireName"
          }
        }
        """,
        "Models/ConstantRecord.swift": """
        struct ConstantRecord {
          static let recordType = "ConstantRecord"
          enum RecordKey {
            static let swiftName = "constantWire"
          }
        }
        """,
        "CloudKit/LiteralRecord.swift": """
        func makeRecord() {
          let record = CKRecord(recordType: "LiteralRecord", recordID: recordID)
          record["literalWire"] = true
        }
        """,
      ],
      schema: """
        RECORD TYPE FieldRecord (
          implicitName STRING,
          wireName STRING,
        );
        RECORD TYPE ConstantRecord (
          constantWire STRING,
        );
        RECORD TYPE LiteralRecord (
          literalWire INT64,
        );
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let fields = try CloudKitSchemaDriftValidator.validate(repoRoot: root)

    XCTAssertEqual(fields["FieldRecord"], ["implicitName", "wireName"])
    XCTAssertEqual(fields["ConstantRecord"], ["constantWire"])
    XCTAssertEqual(fields["LiteralRecord"], ["literalWire"])
  }

  func testGivenUnsupportedDeclarationInNestedPlantedFile_WhenValidating_ThenFailsClosed() throws {
    let root = try makeFixtureRoot(
      sources: [
        "Nested/Planted.swift": """
        struct Planted {
          static let recordType = "Planted"
          enum FieldKey: String {
            case dynamic = generatedKey
          }
        }
        """
      ],
      schema: """
        RECORD TYPE Planted (
          dynamic STRING,
        );
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try CloudKitSchemaDriftValidator.validate(repoRoot: root)) { error in
      guard case .unsupportedDeclaration(let file, let line) = error as? CloudKitSchemaDriftError
      else {
        return XCTFail("Expected unsupportedDeclaration, got \(error)")
      }
      XCTAssertTrue(file.hasSuffix("Foqos/Nested/Planted.swift"))
      XCTAssertEqual(line, "case dynamic = generatedKey")
    }
  }

  func testGivenCodeFieldMissingFromSchema_WhenValidating_ThenReportsField() throws {
    let root = try makeFixtureRoot(
      sources: [
        "CloudKit/MissingField.swift": """
        struct MissingField {
          static let recordType = "MissingField"
          enum FieldKey: String {
            case absent
          }
        }
        """
      ],
      schema: """
        RECORD TYPE MissingField (
          retained STRING,
        );
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try CloudKitSchemaDriftValidator.validate(repoRoot: root)) { error in
      XCTAssertEqual(
        error as? CloudKitSchemaDriftError,
        .missingField(recordType: "MissingField", field: "absent"))
    }
  }

  func testGivenWrittenRecordTypeMissingFromSchema_WhenValidating_ThenReportsType() throws {
    let root = try makeFixtureRoot(
      sources: [
        "CloudKit/MissingType.swift": """
        struct MissingType {
          static let recordType = "MissingType"
          enum FieldKey: String {
            case field
          }
        }
        """
      ],
      schema: """
        RECORD TYPE OtherType (
          field STRING,
        );
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try CloudKitSchemaDriftValidator.validate(repoRoot: root)) { error in
      XCTAssertEqual(error as? CloudKitSchemaDriftError, .missingRecordType("MissingType"))
    }
  }

  func testGivenRepositorySources_WhenValidating_ThenMatchesPinnedBaseline() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let expectedCounts = [
      "SyncedProfile": 42,
      "ProfileSession": 10,
      "SyncedLocation": 8,
      "EmergencySettings": 7,
      "EmergencyUnblockEvent": 5,
      "SyncResetRequest": 4,
      "EmergencyResetEpoch": 2,
      "SyncEstablishment": 2,
      "DeviceHeartbeat": 5,
      "FamilyCommand": 5,
      "FamilyLockCode": 7,
      "FamilyMember": 6,
      "FamilyRoot": 1,
    ]

    let fields = try CloudKitSchemaDriftValidator.validate(repoRoot: repositoryRoot)

    XCTAssertEqual(fields.mapValues(\.count), expectedCounts)
    XCTAssertEqual(fields.count, 13)
    XCTAssertEqual(fields.values.reduce(0) { $0 + $1.count }, 104)
    XCTAssertEqual(fields["FamilyRoot"], ["createdAt"])
  }

  private func makeFixtureRoot(sources: [String: String], schema: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudKitCodeSchemaDriftTests-\(UUID().uuidString)")
    let sourceRoot = root.appendingPathComponent("Foqos")
    let schemaURL = sourceRoot.appendingPathComponent("CloudKit/cloudkit-schema.ckdb")
    try FileManager.default.createDirectory(
      at: schemaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

    for (relativePath, contents) in sources {
      let fileURL = sourceRoot.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return root
  }
}

private enum CloudKitSchemaDriftError: Error, Equatable, CustomStringConvertible {
  case unreadableInput(String)
  case unsupportedDeclaration(file: String, line: String)
  case unableToEnumerate(recordType: String)
  case ambiguousLiteralVariable(file: String, variable: String)
  case missingRecordType(String)
  case missingField(recordType: String, field: String)

  var description: String {
    switch self {
    case .unreadableInput(let path):
      return "Unreadable CloudKit schema input: \(path)"
    case .unsupportedDeclaration(let file, let line):
      return "Unsupported CloudKit field declaration in \(file): \(line)"
    case .unableToEnumerate(let recordType):
      return "Unable to enumerate CloudKit fields for record type: \(recordType)"
    case .ambiguousLiteralVariable(let file, let variable):
      return "Literal CKRecord variable \(variable) maps to multiple record types in \(file)"
    case .missingRecordType(let recordType):
      return "CloudKit schema is missing RECORD TYPE \(recordType)"
    case .missingField(let recordType, let field):
      return "CloudKit schema is missing \(recordType).\(field)"
    }
  }
}

private struct CloudKitSchemaDriftValidator {
  private static let ignoredFieldlessRecordTypes: Set<String> = ["SyncedSession"]

  static func validate(repoRoot: URL) throws -> [String: Set<String>] {
    let sourceRoot = repoRoot.appendingPathComponent("Foqos")
    let schemaURL = sourceRoot.appendingPathComponent("CloudKit/cloudkit-schema.ckdb")
    let sourceURLs = try swiftSourceURLs(below: sourceRoot)
    guard let schema = try? String(contentsOf: schemaURL, encoding: .utf8), !schema.isEmpty else {
      throw CloudKitSchemaDriftError.unreadableInput(schemaURL.path)
    }

    var codeFields: [String: Set<String>] = [:]
    for sourceURL in sourceURLs {
      guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
        throw CloudKitSchemaDriftError.unreadableInput(sourceURL.path)
      }
      merge(try keyedFields(in: source, file: sourceURL.path), into: &codeFields)
      merge(try literalFields(in: source, file: sourceURL.path), into: &codeFields)
    }

    let schemaFields = try parsedSchemaFields(from: schema, file: schemaURL.path)
    for recordType in codeFields.keys.sorted() {
      guard let availableFields = schemaFields[recordType] else {
        throw CloudKitSchemaDriftError.missingRecordType(recordType)
      }
      for field in (codeFields[recordType] ?? []).sorted() where !availableFields.contains(field) {
        throw CloudKitSchemaDriftError.missingField(recordType: recordType, field: field)
      }
    }
    return codeFields
  }

  private static func swiftSourceURLs(below sourceRoot: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
      throw CloudKitSchemaDriftError.unreadableInput(sourceRoot.path)
    }

    var sourceURLs: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      sourceURLs.append(url)
    }
    guard !sourceURLs.isEmpty else {
      throw CloudKitSchemaDriftError.unreadableInput(sourceRoot.path)
    }
    return sourceURLs.sorted { $0.path < $1.path }
  }

  private static func keyedFields(in source: String, file: String) throws
    -> [String: Set<String>]
  {
    let text = source as NSString
    let recordMatches = try matches(
      #"static\s+let\s+recordType\s*=\s*"([^"]+)""#, in: source)
    let enumMatches = try matches(
      #"(?:private\s+)?enum\s+(FieldKey|RecordKey)\s*(?::\s*String)?\s*\{"#,
      in: source)
    var fieldsByRecordType: [String: Set<String>] = [:]

    for (index, recordMatch) in recordMatches.enumerated() {
      guard let recordType = capture(1, from: recordMatch, in: text) else { continue }
      let nextRecordLocation =
        index + 1 < recordMatches.count ? recordMatches[index + 1].range.location : text.length
      let candidates = enumMatches.filter {
        $0.range.location > recordMatch.range.location && $0.range.location < nextRecordLocation
      }

      if candidates.isEmpty, ignoredFieldlessRecordTypes.contains(recordType) {
        continue
      }
      guard candidates.count == 1, let keyKind = capture(1, from: candidates[0], in: text)
      else {
        throw CloudKitSchemaDriftError.unableToEnumerate(recordType: recordType)
      }

      let enumMatch = candidates[0]
      let openingBrace = enumMatch.range.location + enumMatch.range.length - 1
      let bodyRange = try balancedBodyRange(
        in: text, openingBrace: openingBrace, file: file, declaration: "enum \(keyKind)")
      let body = text.substring(with: bodyRange)
      let fields = try parseKeyBody(body, kind: keyKind, file: file)
      guard !fields.isEmpty else {
        throw CloudKitSchemaDriftError.unableToEnumerate(recordType: recordType)
      }
      fieldsByRecordType[recordType, default: []].formUnion(fields)
    }
    return fieldsByRecordType
  }

  private static func parseKeyBody(_ body: String, kind: String, file: String) throws -> Set<String> {
    let pattern =
      kind == "FieldKey"
      ? #"^case\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*"([^"]+)")?\s*$"#
      : #"^static\s+let\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"([^"]+)"\s*$"#
    let regex = try NSRegularExpression(pattern: pattern)
    var fields: Set<String> = []

    for rawLine in body.components(separatedBy: .newlines) {
      let line = rawLine.components(separatedBy: "//")[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      let text = line as NSString
      let fullRange = NSRange(location: 0, length: text.length)
      guard let match = regex.firstMatch(in: line, range: fullRange) else {
        throw CloudKitSchemaDriftError.unsupportedDeclaration(file: file, line: line)
      }

      if kind == "FieldKey" {
        guard let implicitName = capture(1, from: match, in: text) else {
          throw CloudKitSchemaDriftError.unsupportedDeclaration(file: file, line: line)
        }
        fields.insert(capture(2, from: match, in: text) ?? implicitName)
      } else if let wireName = capture(1, from: match, in: text) {
        fields.insert(wireName)
      }
    }
    return fields
  }

  private static func literalFields(in source: String, file: String) throws
    -> [String: Set<String>]
  {
    let text = source as NSString
    let assignments = try matches(
      #"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*CKRecord\s*\(\s*recordType:\s*"([^"]+)""#,
      in: source)
    var typesByVariable: [String: Set<String>] = [:]
    for assignment in assignments {
      guard let variable = capture(1, from: assignment, in: text),
        let recordType = capture(2, from: assignment, in: text)
      else { continue }
      typesByVariable[variable, default: []].insert(recordType)
    }

    var fieldsByRecordType: [String: Set<String>] = [:]
    for variable in typesByVariable.keys.sorted() {
      guard let recordTypes = typesByVariable[variable], recordTypes.count == 1,
        let recordType = recordTypes.first
      else {
        throw CloudKitSchemaDriftError.ambiguousLiteralVariable(file: file, variable: variable)
      }
      fieldsByRecordType[recordType, default: []] = []

      let escapedVariable = NSRegularExpression.escapedPattern(for: variable)
      let writes = try matches(
        escapedVariable + #"\s*\[\s*([^\]]+)\s*\]\s*="#,
        in: source)
      for write in writes {
        guard let keyExpression = capture(1, from: write, in: text) else { continue }
        let keyText = keyExpression.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let stringLiteral = try NSRegularExpression(pattern: #"^"([^"]+)"$"#)
        let range = NSRange(location: 0, length: keyText.length)
        guard let literalMatch = stringLiteral.firstMatch(in: keyText as String, range: range),
          let field = capture(1, from: literalMatch, in: keyText)
        else {
          throw CloudKitSchemaDriftError.unsupportedDeclaration(
            file: file, line: "\(variable)[\(keyExpression)]")
        }
        fieldsByRecordType[recordType, default: []].insert(field)
      }
    }
    return fieldsByRecordType
  }

  private static func parsedSchemaFields(from schema: String, file: String) throws
    -> [String: Set<String>]
  {
    let header = try NSRegularExpression(
      pattern: #"^RECORD TYPE\s+(?:"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))\s*\($"#)
    var fieldsByRecordType: [String: Set<String>] = [:]
    var currentRecordType: String?

    for rawLine in schema.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if currentRecordType == nil {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        if let match = header.firstMatch(in: line, range: range),
          let recordType = capture(1, from: match, in: text) ?? capture(2, from: match, in: text)
        {
          currentRecordType = recordType
          fieldsByRecordType[recordType, default: []] = []
        }
        continue
      }

      if line == ");" {
        currentRecordType = nil
        continue
      }
      guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix("GRANT "),
        let recordType = currentRecordType,
        let firstToken = line.split(whereSeparator: { $0.isWhitespace }).first
      else { continue }

      let field = String(firstToken).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      guard !field.hasPrefix("___") else { continue }
      fieldsByRecordType[recordType, default: []].insert(field)
    }

    guard currentRecordType == nil, !fieldsByRecordType.isEmpty else {
      throw CloudKitSchemaDriftError.unreadableInput(file)
    }
    return fieldsByRecordType
  }

  private static func balancedBodyRange(
    in text: NSString, openingBrace: Int, file: String, declaration: String
  ) throws -> NSRange {
    var depth = 0
    for location in openingBrace..<text.length {
      switch text.substring(with: NSRange(location: location, length: 1)) {
      case "{":
        depth += 1
      case "}":
        depth -= 1
        if depth == 0 {
          return NSRange(location: openingBrace + 1, length: location - openingBrace - 1)
        }
      default:
        continue
      }
    }
    throw CloudKitSchemaDriftError.unsupportedDeclaration(file: file, line: "unclosed \(declaration)")
  }

  private static func matches(_ pattern: String, in text: String) throws
    -> [NSTextCheckingResult]
  {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  private static func capture(
    _ index: Int, from match: NSTextCheckingResult, in text: NSString
  ) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound else { return nil }
    return text.substring(with: range)
  }

  private static func merge(
    _ additions: [String: Set<String>], into fields: inout [String: Set<String>]
  ) {
    for (recordType, newFields) in additions {
      fields[recordType, default: []].formUnion(newFields)
    }
  }
}
