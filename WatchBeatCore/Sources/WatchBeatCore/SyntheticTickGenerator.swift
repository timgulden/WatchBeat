import Foundation

/// Shape of a synthetic tick waveform.
enum TickShape: Sendable {
    /// Short exponentially-decaying burst around 5 kHz (~4 ms).
    case syntheticMechanical
    /// Softer, lower-frequency click typical of a quartz stepper motor.
    case syntheticQuartz
}

/// Parameters for generating a synthetic watch signal with known ground truth.
struct SyntheticTickParameters: Sendable {
    public let beatRate: StandardBeatRate
    public let durationSeconds: Double
    public let sampleRate: Double
    public let rateErrorSecondsPerDay: Double
    public let beatErrorMilliseconds: Double
    public let jitterStdMicroseconds: Double
    public let snrDb: Double
    public let tickShape: TickShape
    public let seed: UInt64

    public init(
        beatRate: StandardBeatRate,
        durationSeconds: Double = 30.0,
        sampleRate: Double = 48000.0,
        rateErrorSecondsPerDay: Double = 0.0,
        beatErrorMilliseconds: Double = 0.0,
        jitterStdMicroseconds: Double = 0.0,
        snrDb: Double = 40.0,
        tickShape: TickShape = .syntheticMechanical,
        seed: UInt64 = 42
    ) {
        self.beatRate = beatRate
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.jitterStdMicroseconds = jitterStdMicroseconds
        self.snrDb = snrDb
        self.tickShape = tickShape
        self.seed = seed
    }
}

/// The result of synthetic signal generation, including the audio and ground truth tick times.
struct SyntheticSignal: Sendable {
    public let buffer: AudioBuffer
    public let tickTimesSeconds: [Double]
    public let parameters: SyntheticTickParameters
}

/// Generates synthetic watch audio signals for testing.
struct SyntheticTickGenerator {

    public init() {}

    /// Generate a synthetic watch signal with known ground truth.
    public func generate(parameters: SyntheticTickParameters) -> SyntheticSignal {
        var rng = SeededRNG(seed: parameters.seed)

        let nominalPeriod = parameters.beatRate.nominalPeriodSeconds
        // A watch running fast has a shorter true period
        let truePeriod = nominalPeriod * (1.0 - parameters.rateErrorSecondsPerDay / 86400.0)

        // Generate ideal tick times
        let totalSamples = Int(parameters.durationSeconds * parameters.sampleRate)
        var tickTimes: [Double] = []
        var t = 0.0
        var index = 0
        while t < parameters.durationSeconds {
            var tickTime = t

            // Apply beat error for mechanical watches (shift odd/even ticks)
            if !parameters.beatRate.isQuartz && parameters.beatErrorMilliseconds != 0.0 {
                let shift = parameters.beatErrorMilliseconds / 1000.0 / 2.0
                if index % 2 == 0 {
                    tickTime += shift
                } else {
                    tickTime -= shift
                }
            }

            // Apply jitter
            if parameters.jitterStdMicroseconds > 0 {
                let jitterSeconds = gaussianRandom(rng: &rng) * parameters.jitterStdMicroseconds / 1_000_000.0
                tickTime += jitterSeconds
            }

            tickTimes.append(tickTime)
            index += 1
            t += truePeriod
        }

        // Synthesize the tick waveform template
        let tickWaveform = makeTickWaveform(shape: parameters.tickShape, sampleRate: parameters.sampleRate)

        // Place ticks into the output buffer
        var samples = [Float](repeating: 0.0, count: totalSamples)
        for tickTime in tickTimes {
            let centerSample = Int(tickTime * parameters.sampleRate)
            let halfLen = tickWaveform.count / 2
            let startSample = centerSample - halfLen
            for i in 0..<tickWaveform.count {
                let idx = startSample + i
                if idx >= 0 && idx < totalSamples {
                    samples[idx] += tickWaveform[i]
                }
            }
        }

        // Add noise to achieve target SNR
        if parameters.snrDb < 100.0 {
            addNoise(to: &samples, snrDb: parameters.snrDb, rng: &rng)
        }

        let buffer = AudioBuffer(samples: samples, sampleRate: parameters.sampleRate)
        return SyntheticSignal(buffer: buffer, tickTimesSeconds: tickTimes, parameters: parameters)
    }

    // MARK: - Tick waveform synthesis

    private func makeTickWaveform(shape: TickShape, sampleRate: Double) -> [Float] {
        switch shape {
        case .syntheticMechanical:
            return makeMechanicalTick(sampleRate: sampleRate)
        case .syntheticQuartz:
            return makeQuartzTick(sampleRate: sampleRate)
        }
    }

    /// Exponentially-decaying 5 kHz burst, ~4 ms duration.
    private func makeMechanicalTick(sampleRate: Double) -> [Float] {
        let durationSeconds = 0.004
        let frequency = 5000.0
        let decayRate = 1000.0 // 1/e in 1 ms
        let count = Int(durationSeconds * sampleRate)
        var waveform = [Float](repeating: 0.0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = Float(exp(-decayRate * t))
            let carrier = Float(sin(2.0 * .pi * frequency * t))
            waveform[i] = envelope * carrier
        }
        return waveform
    }

    /// Softer, lower-frequency click for quartz stepper motor, ~6 ms duration.
    private func makeQuartzTick(sampleRate: Double) -> [Float] {
        let durationSeconds = 0.006
        let frequency = 2000.0
        let decayRate = 500.0
        let count = Int(durationSeconds * sampleRate)
        var waveform = [Float](repeating: 0.0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = Float(exp(-decayRate * t))
            let carrier = Float(sin(2.0 * .pi * frequency * t))
            waveform[i] = envelope * carrier
        }
        return waveform
    }

    // MARK: - Noise

    private func addNoise(to samples: inout [Float], snrDb: Double, rng: inout SeededRNG) {
        // Compute signal RMS
        var signalPower: Float = 0.0
        for s in samples {
            signalPower += s * s
        }
        signalPower /= Float(samples.count)
        let signalRms = sqrt(signalPower)

        // Target noise RMS from SNR
        let noiseRms = signalRms * Float(pow(10.0, -snrDb / 20.0))

        // Add Gaussian noise
        for i in 0..<samples.count {
            samples[i] += Float(gaussianRandom(rng: &rng)) * noiseRms
        }
    }
}

// MARK: - Deterministic RNG

/// A simple xoshiro256** PRNG for reproducible test signals.
struct SeededRNG: RandomNumberGenerator {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // SplitMix64 to expand the seed into 4 state words
        var s = seed
        func next() -> UInt64 {
            s &+= 0x9e3779b97f4a7c15
            var z = s
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        state = (next(), next(), next(), next())
    }

    mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}

/// Box-Muller transform for Gaussian random numbers.
private func gaussianRandom(rng: inout SeededRNG) -> Double {
    let u1 = max(Double(rng.next()) / Double(UInt64.max), 1e-15)
    let u2 = Double(rng.next()) / Double(UInt64.max)
    return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
}
