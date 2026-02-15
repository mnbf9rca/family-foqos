import Foundation
import Security

enum KeychainHelper {

  private static let service = "com.cynexia.family-foqos"

  static func set(_ value: Int, forKey key: String) {
    setData(Data(String(value).utf8), forKey: key)
  }

  static func set(_ value: Double, forKey key: String) {
    setData(Data(String(value).utf8), forKey: key)
  }

  static func set(_ value: Bool, forKey key: String) {
    setData(Data(String(value ? 1 : 0).utf8), forKey: key)
  }

  static func getInt(forKey key: String) -> Int? {
    guard let data = getData(forKey: key),
      let string = String(data: data, encoding: .utf8)
    else { return nil }
    return Int(string)
  }

  static func getDouble(forKey key: String) -> Double? {
    guard let data = getData(forKey: key),
      let string = String(data: data, encoding: .utf8)
    else { return nil }
    return Double(string)
  }

  static func getBool(forKey key: String) -> Bool? {
    guard let value = getInt(forKey: key) else { return nil }
    return value != 0
  }

  static func delete(forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
  }

  // MARK: - Private

  private static func setData(_ data: Data, forKey key: String) {
    // Try update first
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if updateStatus == errSecItemNotFound {
      // Item doesn't exist, add it
      var addQuery = query
      addQuery[kSecValueData as String] = data
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }

  private static func getData(forKey key: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }
}
