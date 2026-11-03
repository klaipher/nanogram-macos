import XCTest
import CoreMedia
import TelegramMediaPlayer
@testable import TelegramMedia

final class MediaPlayerAudioRendererFormatTests: XCTestCase {
    func testRendererRunsAtTheDecoderRate() {
        let description = audioRendererNativeStreamDescription()
        XCTAssertEqual(description.mSampleRate, Float64(MediaPlayerAudioFormat.sampleRate))
        XCTAssertEqual(description.mSampleRate, 48000)
        XCTAssertEqual(Int(description.mChannelsPerFrame), MediaPlayerAudioFormat.channelCount)
        XCTAssertEqual(Int(mediaPlayerAudioTimescale), MediaPlayerAudioFormat.sampleRate)
    }

    func testSampleIndexAnchorsMatchMediaTime() {
        let pts = CMTime(seconds: 12.345, preferredTimescale: 90000)
        let sampleIndex = CMTimeConvertScale(pts, timescale: mediaPlayerAudioTimescale, method: .roundAwayFromZero).value
        let anchor = CMTimeMake(value: sampleIndex, timescale: mediaPlayerAudioTimescale)
        XCTAssertEqual(CMTimeGetSeconds(anchor), 12.345, accuracy: 1.0 / 48000)
        XCTAssertEqual(sampleIndex, 592560)
    }
}
