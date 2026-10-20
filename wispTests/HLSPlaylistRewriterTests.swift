import AVFoundation
import Foundation
import Testing
@testable import wisp

struct HLSPlaylistRewriterTests {
    private let base = URL(string: "https://api.example.com/hls/live.m3u8?vt=abc")!

    @Test func loaderSchemeRoundTripsAndKeepsQuery() throws {
        let loader = try #require(HLSPlaylistRewriter.loaderURL(for: base))
        #expect(loader.absoluteString == "wisp-https://api.example.com/hls/live.m3u8?vt=abc")
        #expect(HLSPlaylistRewriter.originURL(for: loader) == base)
        #expect(HLSPlaylistRewriter.originURL(for: base) == nil)
        #expect(HLSPlaylistRewriter.loaderURL(for: URL(string: "someapp://example.com/")!) == nil)
    }

    @Test func multivariantChildPlaylistsStayOnLoaderScheme() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,URI="audio/live.m3u8",GROUP-ID="a",NAME="audio",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4d001f,mp4a.40.2",AUDIO="a"
        video/live.m3u8?vt=xyz
        """
        let lines = HLSPlaylistRewriter.rewrite(master, origin: base).components(separatedBy: "\n")
        #expect(lines[1] == #"#EXT-X-MEDIA:TYPE=AUDIO,URI="wisp-https://api.example.com/hls/audio/live.m3u8",GROUP-ID="a",NAME="audio",DEFAULT=YES"#)
        #expect(lines[2].hasPrefix("#EXT-X-STREAM-INF:"))
        #expect(lines[3] == "wisp-https://api.example.com/hls/video/live.m3u8?vt=xyz")
    }

    @Test func lowLatencyMediaPlaylistBecomesWholeSegments() {
        let media = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-PART-INF:PART-TARGET=0.5
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=1.750,CAN-BLOCK-RELOAD=YES
        #EXT-X-PART:URI="10.m4s",DURATION=0.5,INDEPENDENT=YES,BYTERANGE="100@0"
        #EXT-X-PROGRAM-DATE-TIME:2026-10-18T15:30:57.166Z
        #EXTINF:2,
        10.m4s
        #EXT-X-PART:URI="11.m4s",DURATION=0.5,INDEPENDENT=YES,BYTERANGE="100@0"
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.m4s",BYTERANGE-START=100
        #EXT-X-RENDITION-REPORT:URI="../other/live.m3u8",LAST-MSN=11,LAST-PART=0
        """
        #expect(HLSPlaylistRewriter.rewrite(media, origin: base) == """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-MAP:URI="https://api.example.com/hls/init.mp4"
        #EXT-X-PROGRAM-DATE-TIME:2026-10-18T15:30:57.166Z
        #EXTINF:2,
        https://api.example.com/hls/10.m4s
        """)
    }

    @Test func absoluteAndKeyURIsArePreserved() {
        let media = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-id",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:4,
        https://cdn.example.com/seg1.ts
        """
        let lines = HLSPlaylistRewriter.rewrite(media, origin: base).components(separatedBy: "\n")
        #expect(lines[1] == #"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-id",KEYFORMAT="com.apple.streamingkeydelivery""#)
        #expect(lines[3] == "https://cdn.example.com/seg1.ts")
    }

    @Test func playerItemRoutesOnlyHLS() throws {
        let hls = try #require(URL(string: "https://example.com/live.m3u8?token=signed"))
        let hlsItem = HLSPlaylistLoader.playerItem(for: hls)
        let hlsAsset = try #require(hlsItem.asset as? AVURLAsset)
        #expect(hlsAsset.url.absoluteString == "wisp-https://example.com/live.m3u8?token=signed")
        #expect(hlsAsset.resourceLoader.delegate != nil)

        let mp4 = try #require(URL(string: "https://example.com/clip.mp4"))
        let mp4Item = HLSPlaylistLoader.playerItem(for: mp4)
        let mp4Asset = try #require(mp4Item.asset as? AVURLAsset)
        #expect(mp4Asset.url == mp4)
        #expect(mp4Asset.resourceLoader.delegate == nil)
    }
}
