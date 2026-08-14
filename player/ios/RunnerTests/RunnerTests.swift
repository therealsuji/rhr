import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testAckDecoderRejectsTruncatedPayloads() {
    XCTAssertNil(RhrSessionService.decodeAckCount([]))
    XCTAssertNil(RhrSessionService.decodeAckCount([0, 0, 0]))
  }

  func testAckDecoderReadsBigEndianCount() {
    XCTAssertEqual(
      RhrSessionService.decodeAckCount([0x01, 0x02, 0x03, 0x04]),
      0x01020304)
  }

}
