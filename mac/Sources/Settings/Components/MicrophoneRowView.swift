import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

final class MicrophoneRowView: NSView {
    let uid: String
    var onClick: ((String) -> Void)?

    init(uid: String) {
        self.uid = uid
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(uid)
    }
}
