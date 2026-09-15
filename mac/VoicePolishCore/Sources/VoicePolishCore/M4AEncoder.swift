import Foundation
import AVFoundation

/// 上传用 AAC/M4A 编码工具：将 Float32 PCM 样本压缩为 m4a Data。
/// 体积约为 WAV 的 1/10，弱网环境上传更快、更不易超时。
/// 编码参数与 AudioClipStore 的历史存档一致（已实测各 ASR 接口识别结果与 WAV 一字不差）。
public enum M4AEncoder {
    public static func makeM4AData(from samples: [Float], sampleRate: Int) -> Data? {
        guard !samples.isEmpty else { return nil }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(sampleRate),
                                            channels: 1,
                                            interleaved: false) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24000,  // 24kbps 单声道语音，与历史存档一致
        ]

        do {
            let file = try AVAudioFile(forWriting: tmpURL, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress, let dst = buffer.floatChannelData?[0] {
                    dst.update(from: base, count: samples.count)
                }
            }
            try file.write(from: buffer)
        } catch {
            return nil
        }

        return try? Data(contentsOf: tmpURL)
    }
}
