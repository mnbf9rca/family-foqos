// FoqosTests/DataExporterTests.swift
import XCTest

@testable import FamilyFoqos

final class DataExporterTests: XCTestCase {

  // MARK: - CSV Formula Injection Guard

  func testGivenFieldStartingWithEquals_WhenEscaping_ThenPrefixesWithTab() {
    let result = DataExporter.escapeCSVField("=CMD(calc)")
    XCTAssertTrue(result.hasPrefix("\t"))
    XCTAssertEqual(result, "\t=CMD(calc)")
  }

  func testGivenFieldStartingWithPlus_WhenEscaping_ThenPrefixesWithTab() {
    let result = DataExporter.escapeCSVField("+1234")
    XCTAssertEqual(result, "\t+1234")
  }

  func testGivenFieldStartingWithMinus_WhenEscaping_ThenPrefixesWithTab() {
    let result = DataExporter.escapeCSVField("-1234")
    XCTAssertEqual(result, "\t-1234")
  }

  func testGivenFieldStartingWithAt_WhenEscaping_ThenPrefixesWithTab() {
    let result = DataExporter.escapeCSVField("@SUM(A1)")
    XCTAssertEqual(result, "\t@SUM(A1)")
  }

  func testGivenFormulaFieldWithComma_WhenEscaping_ThenTabPrefixedAndQuoted() {
    let result = DataExporter.escapeCSVField("=1+2,3")
    // Tab prefix applied first, then quoting wraps it
    XCTAssertEqual(result, "\"\t=1+2,3\"")
  }

  func testGivenNormalField_WhenEscaping_ThenPassesThroughUnchanged() {
    XCTAssertEqual(DataExporter.escapeCSVField("hello"), "hello")
  }

  func testGivenFieldWithComma_WhenEscaping_ThenQuoted() {
    XCTAssertEqual(DataExporter.escapeCSVField("a,b"), "\"a,b\"")
  }

  func testGivenEmptyField_WhenEscaping_ThenReturnsEmpty() {
    XCTAssertEqual(DataExporter.escapeCSVField(""), "")
  }
}
