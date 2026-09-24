import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
