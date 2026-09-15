import Foundation

/// WAV 编码工具：将 Float32 PCM 样本转为 WAV 格式 Data
public enum WAVEncoder {
    public static func makeWAVData(from samples: [Float], sampleRate: Int) -> Data? {
        guard !samples.isEmpty else { return nil }

        var pcmData = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var intSample = Int16((clamped * Float(Int16.max)).rounded())
            pcmData.append(Data(bytes: &intSample, count: MemoryLayout<Int16>.size))
        }

        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = UInt32(36) + subchunk2Size
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(1))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(subchunk2Size))
        data.append(pcmData)
        return data
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size)
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
    }
}
