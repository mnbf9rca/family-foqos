import CloudKit
import Foundation

public func redactedErrorForLog(_ error: any Error) -> String {
  var redactor = ErrorLogRedactor()
  return redactor.redact(error)
}

private struct ErrorLogRedactor {
  private let maxDepth = 3
  private let maxCharacters = 2_048
  private var visitedErrorIds: Set<ObjectIdentifier> = []

  mutating func redact(_ error: any Error) -> String {
    bounded(format(error, depth: 0))
  }

  private mutating func format(_ error: any Error, depth: Int) -> String {
    guard depth <= maxDepth else { return "[depth limit]" }

    let mirror = Mirror(reflecting: error)
    if !(error is any LocalizedError), mirror.displayStyle == .enum {
      return formatNativeEnum(error, mirror: mirror, depth: depth)
    }

    let nsError = error as NSError
    let errorId = errorIdentity(for: error, mirror: mirror, nsError: nsError)
    guard visitedErrorIds.insert(errorId).inserted else { return "[cycle]" }
    defer { visitedErrorIds.remove(errorId) }

    var components = [
      "domain=\(nsError.domain)",
      "code=\(nsError.code)",
      "description=\(nsError.localizedDescription)",
    ]

    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
      components.append("underlying={\(format(underlying, depth: depth + 1))}")
    }
    components.append(contentsOf: partialErrorComponents(nsError, depth: depth))
    return components.joined(separator: " ")
  }

  private mutating func formatNativeEnum(
    _ error: any Error,
    mirror: Mirror,
    depth: Int
  ) -> String {
    let typeName = String(reflecting: type(of: error))
    guard let associated = mirror.children.first else {
      return "\(typeName).\(String(describing: error))"
    }

    let caseName = associated.label ?? "unknown"
    var components = ["\(typeName).\(caseName)"]
    for nestedError in errors(in: associated.value) {
      components.append("nested={\(format(nestedError, depth: depth + 1))}")
    }
    return components.joined(separator: " ")
  }

  private func errors(in value: Any) -> [any Error] {
    if let error = value as? any Error {
      return [error]
    }

    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .tuple || mirror.displayStyle == .optional else { return [] }
    return mirror.children.flatMap { errors(in: $0.value) }
  }

  private mutating func partialErrorComponents(_ error: NSError, depth: Int) -> [String] {
    guard let partials = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] else {
      return []
    }

    return partials.compactMap { key, value -> (String, any Error)? in
      guard let nestedError = value as? any Error, let label = opaqueLabel(for: key) else {
        return nil
      }
      return (label, nestedError)
    }
    .sorted { $0.0 < $1.0 }
    .map { label, nestedError in
      "partial[\(label)]={\(format(nestedError, depth: depth + 1))}"
    }
  }

  private func opaqueLabel(for key: AnyHashable) -> String? {
    if let recordID = key.base as? CKRecord.ID {
      return "record=\(recordID.recordName) zone=\(recordID.zoneID.zoneName)"
    }
    if let zoneID = key.base as? CKRecordZone.ID {
      return "zone=\(zoneID.zoneName)"
    }
    if let identifier = key.base as? String {
      return "item=\(identifier)"
    }
    return nil
  }

  private func errorIdentity(
    for error: any Error,
    mirror: Mirror,
    nsError: NSError
  ) -> ObjectIdentifier {
    if mirror.displayStyle == .class {
      return ObjectIdentifier(error as AnyObject)
    }
    return ObjectIdentifier(nsError)
  }

  private func bounded(_ value: String) -> String {
    let singleLine =
      value
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    return String(singleLine.prefix(maxCharacters))
  }
}
