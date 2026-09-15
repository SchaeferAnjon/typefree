import AVFoundation
import AudioToolbox
import Foundation

/// 键盘扩展录音器，使用 AudioToolbox Audio Queue Services（最底层 C API）
public class SimpleAudioRecorder: NSObject {
    private var audioQueue: AudioQueueRef?
    private var levelCallback: ((Float) -> Void)?
    private var sampleBuffers: [[Float]] = []
    private let lock = NSLock()
    private var isCapturing = false
    private var recordFormat = AudioStreamBasicDescription()

    // Audio Queue 需要的 buffer 数量
    private let kNumberBuffers: Int = 3
    private let kBufferDuration: Double = 0.1  // 每个 buffer 100ms
    private var buffers: [AudioQueueBufferRef?] = []

    public override init() {
        super.init()
    }

    public func prepare() {}

    /// 开始录音，返回 nil 表示成功，非 nil 为错误信息
    public func startRecording(levelUpdate: @escaping (Float) -> Void) -> String? {
        #if os(iOS)
        // 1. 检查权限
        let permStatus = AVAudioSession.sharedInstance().recordPermission
        if permStatus == .denied {
            return "麦克风权限被拒绝"
        }

        // 2. 激活音频会话
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            NSLog("[Recorder] Session active, sampleRate=%.0f", session.sampleRate)
        } catch {
            return "音频会话: \(error.localizedDescription)"
        }
        #endif

        // 3. 配置录音格式：16kHz mono 16-bit PCM
        recordFormat = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        levelCallback = levelUpdate
        lock.lock()
        sampleBuffers = []
        lock.unlock()
        isCapturing = true

        // 4. 创建 Audio Queue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var queue: AudioQueueRef?
        var status = AudioQueueNewInput(
            &recordFormat,
            audioQueueCallback,
            selfPtr,
            nil,  // run loop
            nil,  // run loop mode
            0,    // flags
            &queue
        )

        guard status == noErr, let audioQueue = queue else {
            isCapturing = false
            return "AudioQueue创建失败: \(status)"
        }

        self.audioQueue = audioQueue

        // 5. 分配 buffers
        let bufferSize = UInt32(recordFormat.mSampleRate * kBufferDuration) * recordFormat.mBytesPerFrame
        buffers = [AudioQueueBufferRef?](repeating: nil, count: kNumberBuffers)

        for i in 0..<kNumberBuffers {
            status = AudioQueueAllocateBuffer(audioQueue, bufferSize, &buffers[i])
            guard status == noErr, let buffer = buffers[i] else {
                AudioQueueDispose(audioQueue, true)
                self.audioQueue = nil
                isCapturing = false
                return "Buffer分配失败: \(status)"
            }
            status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
            guard status == noErr else {
                AudioQueueDispose(audioQueue, true)
                self.audioQueue = nil
                isCapturing = false
                return "Buffer入队失败: \(status)"
            }
        }

        // 6. 启动录音
        status = AudioQueueStart(audioQueue, nil)
        guard status == noErr else {
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
            isCapturing = false
            return "AudioQueue启动失败: \(status)"
        }

        NSLog("[Recorder] AudioQueue started, 16kHz mono Int16")
        return nil  // 成功
    }

    /// 停止录音并返回 16kHz Float32 样本
    public func stopRecording(completion: @escaping ([Float]?) -> Void) {
        isCapturing = false

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        audioQueue = nil
        levelCallback = nil

        NSLog("[Recorder] AudioQueue stopped")

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // 读取采集的数据
        lock.lock()
        let allBuffers = sampleBuffers
        sampleBuffers = []
        lock.unlock()

        NSLog("[Recorder] Collected %d chunks", allBuffers.count)

        var allSamples: [Float] = []
        for buf in allBuffers {
            allSamples.append(contentsOf: buf)
        }

        if allSamples.isEmpty {
            completion(nil)
        } else {
            NSLog("[Recorder] Total: %d samples (%.1f sec)", allSamples.count, Float(allSamples.count) / 16000.0)
            completion(allSamples)
        }
    }

    // MARK: - Audio Queue Callback (C function)

    fileprivate func handleAudioBuffer(_ buffer: AudioQueueBufferRef) {
        guard isCapturing else { return }

        let dataSize = Int(buffer.pointee.mAudioDataByteSize)
        let sampleCount = dataSize / MemoryLayout<Int16>.size

        guard sampleCount > 0 else {
            // 重新入队
            if let queue = audioQueue {
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            }
            return
        }

        // Int16 → Float32
        let int16Ptr = buffer.pointee.mAudioData.bindMemory(to: Int16.self, capacity: sampleCount)
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            floatSamples[i] = Float(int16Ptr[i]) / Float(Int16.max)
        }

        lock.lock()
        if sampleBuffers.isEmpty {
            NSLog("[Recorder] First audio data! %d samples", sampleCount)
        }
        sampleBuffers.append(floatSamples)
        lock.unlock()

        // 计算音量
        var peak: Float = 0
        var rms: Float = 0
        for sample in floatSamples {
            rms += sample * sample
            let abs = Swift.abs(sample)
            if abs > peak { peak = abs }
        }
        rms = sqrt(rms / max(Float(sampleCount), 1))
        let level = min(max(peak * 6.0, rms * 15.0), 1.0)

        DispatchQueue.main.async { [weak self] in
            self?.levelCallback?(level)
        }

        // 重新入队 buffer
        if let queue = audioQueue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }
}

// MARK: - C Callback

private func audioQueueCallback(
    _ inUserData: UnsafeMutableRawPointer?,
    _ inAQ: AudioQueueRef,
    _ inBuffer: AudioQueueBufferRef,
    _ inStartTime: UnsafePointer<AudioTimeStamp>,
    _ inNumberPacketDescriptions: UInt32,
    _ inPacketDescs: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData = inUserData else { return }
    let recorder = Unmanaged<SimpleAudioRecorder>.fromOpaque(userData).takeUnretainedValue()
    recorder.handleAudioBuffer(inBuffer)
}
