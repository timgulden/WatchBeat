import Foundation

/// Reads a 32-bit float mono WAV file into an AudioBuffer.
public struct WAVReader {
    public enum WAVError: Error {
        case invalidFormat(String)
    }

    public static func read(url: URL) throws -> AudioBuffer {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else {
            throw WAVError.invalidFormat("File too small for WAV header")
        }

        // Parse RIFF header
        let riff = String(data: data[0..<4], encoding: .ascii)
        guard riff == "RIFF" else {
            throw WAVError.invalidFormat("Not a RIFF file")
        }

        let wave = String(data: data[8..<12], encoding: .ascii)
        guard wave == "WAVE" else {
            throw WAVError.invalidFormat("Not a WAVE file")
        }

        // Parse fmt chunk
        let fmt = String(data: data[12..<16], encoding: .ascii)
        guard fmt == "fmt " else {
            throw WAVError.invalidFormat("Missing fmt chunk")
        }

        let audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self).littleEndian }
        let numChannels = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self).littleEndian }
        let sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self).littleEndian }

        guard audioFormat == 3 else {
            throw WAVError.invalidFormat("Expected IEEE float format (3), got \(audioFormat)")
        }
        guard numChannels == 1 else {
            throw WAVError.invalidFormat("Expected mono, got \(numChannels) channels")
        }

        // Find data chunk (skip past fmt chunk)
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(data.withUnsafeBytes {
                $0.load(fromByteOffset: offset + 4, as: UInt32.self).littleEndian
            })

            if chunkID == "data" {
                let dataStart = offset + 8
                let numSamples = chunkSize / 4

                var samples = [Float](repeating: 0, count: numSamples)
                data.withUnsafeBytes { rawBuf in
                    let floatBuf = rawBuf.baseAddress!.advanced(by: dataStart)
                        .assumingMemoryBound(to: Float.self)
                    for i in 0..<numSamples {
                        samples[i] = floatBuf[i]
                    }
                }

                return AudioBuffer(samples: samples, sampleRate: Double(sampleRate))
            }

            offset += 8 + chunkSize
            if chunkSize % 2 != 0 { offset += 1 } // padding
        }

        throw WAVError.invalidFormat("No data chunk found")
    }
}
