import XCTest
import CoreAudio
@testable import MacNotchIsland

/// Exercises the pure parts of the audio tap: the RMS reduction and the two curves that
/// turn it into a bar height. Nothing here creates a tap, so no audio-capture consent and
/// no macOS 14.2 is needed — these run on every machine CI hands us.
final class AudioLevelTapTests: XCTestCase {
    // MARK: levelFromRMS

    func testSilenceIsZero() {
        XCTAssertEqual(AudioLevelTap.levelFromRMS(0), 0)
    }

    func testFullScaleIsOne() {
        XCTAssertEqual(AudioLevelTap.levelFromRMS(1), 1, accuracy: 0.0001)
    }

    func testAnythingBelowTheFloorIsZero() {
        // -50 dB is the floor, so -60 dB (0.001) and below must read as silence.
        XCTAssertEqual(AudioLevelTap.levelFromRMS(0.001), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelTap.levelFromRMS(0.0000001), 0)
    }

    func testHalfwayIsMinusTwentyFiveDecibels() {
        // 10^(-25/20) ≈ 0.0562 sits exactly half way up the 50 dB window.
        XCTAssertEqual(AudioLevelTap.levelFromRMS(0.0562341), 0.5, accuracy: 0.001)
    }

    func testMonotonicallyIncreasing() {
        let inputs: [Float] = [0, 0.0001, 0.001, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 1]
        var previous = -1.0
        for input in inputs {
            let level = AudioLevelTap.levelFromRMS(input)
            XCTAssertGreaterThanOrEqual(level, previous, "level fell at rms \(input)")
            previous = level
        }
    }

    func testAlwaysClampedToUnitRange() {
        let inputs: [Float] = [-5, -0.5, 0, 0.3, 1, 4, 1000]
        for input in inputs {
            let level = AudioLevelTap.levelFromRMS(input)
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }

    func testNonFiniteInputIsSilence() {
        XCTAssertEqual(AudioLevelTap.levelFromRMS(Float.nan), 0)
        XCTAssertEqual(AudioLevelTap.levelFromRMS(Float.infinity), 0)
        XCTAssertEqual(AudioLevelTap.levelFromRMS(-Float.infinity), 0)
    }

    // MARK: smoothed

    func testAttackIsFasterThanRelease() {
        let rise = AudioLevelTap.smoothed(previous: 0, target: 1) - 0
        let fall = 1 - AudioLevelTap.smoothed(previous: 1, target: 0)
        XCTAssertGreaterThan(rise, fall, "bars must jump up faster than they sink")
        XCTAssertEqual(rise, AudioLevelTap.attack, accuracy: 0.0001)
        XCTAssertEqual(fall, AudioLevelTap.release, accuracy: 0.0001)
    }

    func testSmoothingMovesTowardsTheTarget() {
        XCTAssertGreaterThan(AudioLevelTap.smoothed(previous: 0.2, target: 0.9), 0.2)
        XCTAssertLessThan(AudioLevelTap.smoothed(previous: 0.9, target: 0.2), 0.9)
    }

    func testSteadyLevelIsLeftAlone() {
        XCTAssertEqual(AudioLevelTap.smoothed(previous: 0.42, target: 0.42), 0.42, accuracy: 0.0001)
    }

    func testSmoothingConverges() {
        var value = 0.0
        for _ in 0..<64 { value = AudioLevelTap.smoothed(previous: value, target: 1) }
        XCTAssertEqual(value, 1, accuracy: 0.01)
        for _ in 0..<256 { value = AudioLevelTap.smoothed(previous: value, target: 0) }
        XCTAssertEqual(value, 0, accuracy: 0.01)
    }

    func testSmoothingStaysInUnitRange() {
        XCTAssertEqual(AudioLevelTap.smoothed(previous: 2, target: 5), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelTap.smoothed(previous: -3, target: -1), 0, accuracy: 0.0001)
    }

    // MARK: rms

    func testRMSOfOneInterleavedBuffer() {
        var samples = [Float32](repeating: 0.5, count: 256)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        samples.withUnsafeMutableBytes { raw in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            XCTAssertEqual(AudioLevelTap.rms(of: list.unsafeMutablePointer), 0.5, accuracy: 0.0001)
        }
    }

    func testRMSAveragesAcrossNonInterleavedBuffers() {
        var left = [Float32](repeating: 1, count: 128)
        var right = [Float32](repeating: 0, count: 128)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        left.withUnsafeMutableBytes { leftRaw in
            right.withUnsafeMutableBytes { rightRaw in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftRaw.count), mData: leftRaw.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightRaw.count), mData: rightRaw.baseAddress)
                // sqrt((1 + 0) / 2)
                XCTAssertEqual(AudioLevelTap.rms(of: list.unsafeMutablePointer), 0.7071, accuracy: 0.0005)
            }
        }
    }

    func testRMSOfAnEmptyListIsZero() {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        XCTAssertEqual(AudioLevelTap.rms(of: list.unsafeMutablePointer), 0)
    }

    // MARK: end to end

    func testLoudSignalDrivesTheBarsHigherThanAQuietOne() {
        let quiet = AudioLevelTap.levelFromRMS(0.01)
        let loud = AudioLevelTap.levelFromRMS(0.4)
        XCTAssertLessThan(quiet, loud)
        XCTAssertGreaterThan(AudioLevelTap.smoothed(previous: quiet, target: loud), quiet)
    }
}
