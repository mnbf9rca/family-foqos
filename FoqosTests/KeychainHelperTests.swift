import XCTest

@testable import FamilyFoqos

final class KeychainHelperTests: XCTestCase {

  private let testKey = "family_foqos_test_key"

  override func tearDown() {
    KeychainHelper.delete(forKey: testKey)
  }

  func testGivenNoValue_WhenGetInt_ThenReturnsNil() {
    XCTAssertNil(KeychainHelper.getInt(forKey: testKey))
  }

  func testGivenIntSet_WhenGetInt_ThenReturnsValue() {
    KeychainHelper.set(42, forKey: testKey)
    XCTAssertEqual(KeychainHelper.getInt(forKey: testKey), 42)
  }

  func testGivenIntSet_WhenSetAgain_ThenReturnsUpdatedValue() {
    KeychainHelper.set(1, forKey: testKey)
    KeychainHelper.set(2, forKey: testKey)
    XCTAssertEqual(KeychainHelper.getInt(forKey: testKey), 2)
  }

  func testGivenDoubleSet_WhenGetDouble_ThenReturnsValue() {
    KeychainHelper.set(3.14, forKey: testKey)
    XCTAssertEqual(KeychainHelper.getDouble(forKey: testKey), 3.14)
  }

  func testGivenBoolTrue_WhenGetBool_ThenReturnsTrue() {
    KeychainHelper.set(true, forKey: testKey)
    XCTAssertEqual(KeychainHelper.getBool(forKey: testKey), true)
  }

  func testGivenBoolFalse_WhenGetBool_ThenReturnsFalse() {
    KeychainHelper.set(false, forKey: testKey)
    XCTAssertEqual(KeychainHelper.getBool(forKey: testKey), false)
  }

  func testGivenValue_WhenDelete_ThenReturnsNil() {
    KeychainHelper.set(99, forKey: testKey)
    KeychainHelper.delete(forKey: testKey)
    XCTAssertNil(KeychainHelper.getInt(forKey: testKey))
  }
}
