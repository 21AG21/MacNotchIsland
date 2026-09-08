import XCTest
@testable import MacNotchIsland

final class CrashReportsTests: XCTestCase {
    /// The shape ReportCrash writes: a one-line header, a blank line, then the report.
    private let report = """
    {"app_name":"MacNotchIsland","timestamp":"2026-09-07 21:04:13.00 -0700","app_version":"1.0.0","build_version":"1","bundleID":"com.macnotchisland.app","bug_type":"309","os_version":"macOS 27.0 (26A5425a)","name":"MacNotchIsland"}

    {"procName":"MacNotchIsland","pid":57786,"faultingThread":0,
     "exception":{"codes":"0x0000000000000001, 0x0000000000000000","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
     "termination":{"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":57786},
     "asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},
     "usedImages":[{"name":"MacNotchIsland","path":"/Applications/MacNotchIsland.app/Contents/MacOS/MacNotchIsland"},{"name":"libswiftCore.dylib"}],
     "threads":[{"triggered":true,"id":1,"queue":"com.apple.main-thread","frames":[
        {"imageOffset":123,"symbol":"_assertionFailure","symbolLocation":10,"imageIndex":1},
        {"imageOffset":4567,"symbol":"ActivityCenter.open(_:direction:)","symbolLocation":88,"imageIndex":0},
        {"imageOffset":8910,"imageIndex":0}]},
      {"id":2,"frames":[{"imageOffset":1,"imageIndex":1}]}]}
    """

    func testSummaryKeepsWhatExplainsTheEnd() {
        let summary = CrashReports.summary(ofReport: report)
        XCTAssertTrue(summary.contains("reported 2026-09-07 21:04:13.00 -0700 app 1.0.0 (1) on macOS 27.0 (26A5425a)"), summary)
        XCTAssertTrue(summary.contains("termination SIGNAL code 5 Trace/BPT trap: 5 by exc handler pid 57786"), summary)
        XCTAssertTrue(summary.contains("exception EXC_BREAKPOINT SIGTRAP codes 0x0000000000000001, 0x0000000000000000"), summary)
        XCTAssertTrue(summary.contains("libswiftCore.dylib: Fatal error: Index out of range"), summary)
        XCTAssertTrue(summary.contains("thread 0 com.apple.main-thread:"), summary)
        XCTAssertTrue(summary.contains("  1 MacNotchIsland ActivityCenter.open(_:direction:) + 88"), summary)
        XCTAssertTrue(summary.contains("  2 MacNotchIsland + 8910"), "unsymbolicated frames show their offset: \(summary)")
        XCTAssertFalse(summary.contains("thread 1"), "only the faulting thread is reported: \(summary)")
    }

    func testPrivacyKillIsReadable() {
        let tcc = """
        {"app_name":"MacNotchIsland","timestamp":"2026-09-07 21:04:13.00 -0700","app_version":"1.0.0","build_version":"1","os_version":"macOS 27.0 (26A5425a)"}

        {"termination":{"namespace":"TCC","code":0,"indicator":"This app has crashed because it attempted to access privacy-sensitive data without a usage description."},
         "exception":{"type":"EXC_CRASH","signal":"SIGKILL"},"threads":[]}
        """
        let summary = CrashReports.summary(ofReport: tcc)
        XCTAssertTrue(summary.contains("termination TCC code 0 This app has crashed"), summary)
        XCTAssertTrue(summary.contains("exception EXC_CRASH SIGKILL"), summary)
    }

    func testGarbageDoesNotTrap() {
        XCTAssertEqual(CrashReports.summary(ofReport: ""), "unreadable report")
        XCTAssertEqual(CrashReports.summary(ofReport: "{}\n\nnot json"), "unreadable report body")
        XCTAssertFalse(CrashReports.recentSummaries().isEmpty)
    }
}
