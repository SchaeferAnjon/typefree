import AVFoundation
import Foundation

public class AudioRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var levelCallback: ((Float) -> Void)?
    private var rawBuffers: [AVAudioPCMBuffer] = []
    private let bufferQueue = DispatchQueue(label: "audio.buffer")
    private var isCapturing = false

    public override init() {
        super.init()
    }

    /// 返回 nil 表示成功，非 nil 为错误信息
    public func startRecording(levelUpdate: @escaping (Float) -> Void) -> String? {
        // 清理旧引擎
        teardownEngine()

        #if os(iOS)
        // iOS：每次录音前激活音频会话
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            NSLog("[AudioRecorder] AVAudioSession activated (category=record)")
        } catch {
            let msg = "音频会话激活失败: \(error.localizedDescription)"
            NSLog("[AudioRecorder] %@", msg)
            return msg
        }
        #endif

        // 创建新引擎
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioRecorder] Native format: sampleRate=%.0f channels=%d", nativeFormat.sampleRate, nativeFormat.channelCount)

        guard nativeFormat.channelCount > 0 else {
            return "没有检测到麦克风输入"
        }

        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeFormat.sampleRate,
            channels: nativeFormat.channelCount,
            interleaved: false
        ) ?? nativeFormat

        levelCallback = levelUpdate
        bufferQueue.sync {
            self.rawBuffers.removeAll(keepingCapacity: true)
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }

            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            self.bufferQueue.async {
                self.rawBuffers.append(copy)
            }

            if let channelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var rms: Float = 0
                for i in 0..<count {
                    let sample = channelData[0][i]
                    rms += sample * sample
                }
                rms = sqrt(rms / max(Float(count), 1))
                var peak: Float = 0
                for i in 0..<count {
                    let v = Swift.abs(channelData[0][i])
                    if v > peak { peak = v }
                }
                let level = min(max(peak * 6.0, rms * 15.0), 1.0)
                self.levelCallback?(level)
            }
        }

        isCapturing = true

        do {
            try engine.start()
            NSLog("[AudioRecorder] Engine started, recording")
            return nil  // 成功
        } catch {
            isCapturing = false
            levelCallback = nil
            teardownEngine()
            let msg = error.localizedDescription
            NSLog("[AudioRecorder] Engine start failed: %@", msg)
            return msg
        }
    }

    public func stopRecording(completion: @escaping ([Float]?) -> Void) {
        isCapturing = false
        levelCallback = nil
        NSLog("[AudioRecorder] Capturing stopped")
        engine?.stop()

        let capturedBuffers = bufferQueue.sync { () -> [AVAudioPCMBuffer] in
            let captured = self.rawBuffers
            self.rawBuffers.removeAll(keepingCapacity: true)
            return captured
        }

        NSLog("[AudioRecorder] Captured %d buffers", capturedBuffers.count)
        processBuffers(capturedBuffers, completion: completion)

        // 录完后清理
        teardownEngine()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// macOS 兼容：预热（iOS 上不需要提前调用）
    public func prepare() {
        // iOS 上不做预热，所有初始化在 startRecording 里完成
        // macOS 上也简化为空操作，startRecording 会处理
    }

    private func teardownEngine() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func processBuffers(_ capturedBuffers: [AVAudioPCMBuffer], completion: @escaping ([Float]?) -> Void) {
        guard !capturedBuffers.isEmpty else {
            completion(nil)
            return
        }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: false)!

        var allSamples: [Float] = []
        var currentFormat: AVAudioFormat? = nil
        var currentBuffers: [AVAudioPCMBuffer] = []

        for buf in capturedBuffers {
            if currentFormat == nil || buf.format == currentFormat! {
                currentFormat = buf.format
                currentBuffers.append(buf)
            } else {
                if let converted = convertBuffers(currentBuffers, from: currentFormat!, to: outputFormat) {
                    allSamples.append(contentsOf: converted)
                }
                currentFormat = buf.format
                currentBuffers = [buf]
            }
        }
        if !currentBuffers.isEmpty, let fmt = currentFormat {
            if let converted = convertBuffers(currentBuffers, from: fmt, to: outputFormat) {
                allSamples.append(contentsOf: converted)
            }
        }

        NSLog("[AudioRecorder] Total converted: %d samples (%.1f sec)", allSamples.count, Float(allSamples.count) / 16000.0)
        completion(allSamples.isEmpty ? nil : allSamples)
    }

    private func convertBuffers(_ buffers: [AVAudioPCMBuffer], from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> [Float]? {
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0 else { return nil }

        guard let merged = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        merged.frameLength = AVAudioFrameCount(totalFrames)

        var offset = 0
        for buf in buffers {
            let frames = Int(buf.frameLength)
            if let src = buf.floatChannelData, let dst = merged.floatChannelData {
                for ch in 0..<Int(inputFormat.channelCount) {
                    memcpy(dst[ch].advanced(by: offset), src[ch], frames * MemoryLayout<Float>.size)
                }
            }
            offset += frames
        }

        if inputFormat.sampleRate == outputFormat.sampleRate && inputFormat.channelCount == outputFormat.channelCount {
            guard let data = merged.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: totalFrames))
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        let outputFrameCount = AVAudioFrameCount(Double(totalFrames) * outputFormat.sampleRate / inputFormat.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return merged
        }

        if let error = error {
            NSLog("[AudioRecorder] Conversion error: %@", error.localizedDescription)
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        teardownEngine()
    }

    public enum RecorderError: Error {
        case engineUnavailable
    }
}
