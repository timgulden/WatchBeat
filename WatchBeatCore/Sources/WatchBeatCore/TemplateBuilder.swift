import Foundation
import Accelerate

/// Folds raw signal at the detected period to build an averaged tick template.
public struct TemplateBuilder {

    public init() {}

    /// Build a tick template by folding the filtered signal at the detected period.
    ///
    /// For mechanical rates, folds at 2x the beat period to capture a tick-tock pair.
    /// For quartz, folds at 1x the beat period (single click per cycle).
    ///
    /// - Parameters:
    ///   - filtered: Bandpass-filtered signal at full sample rate.
    ///   - periodEstimate: Result from PeriodEstimator.
    /// - Returns: Averaged, normalized tick template.
    public func build(filtered: AudioBuffer, periodEstimate: PeriodEstimate) -> TickTemplate {
        let sampleRate = filtered.sampleRate
        let samples = filtered.samples
        let measuredHz = periodEstimate.measuredHz

        // Determine fold period: 2 beats for mechanical (tick+tock pair), 1 for quartz
        let beatsPerTemplate = periodEstimate.snappedRate.isQuartz ? 1 : 2
        let foldSamples = Int(round(Double(beatsPerTemplate) * sampleRate / measuredHz))

        guard foldSamples > 0 && foldSamples < samples.count else {
            // Edge case: return whatever we have
            return TickTemplate(samples: [0], sampleRate: sampleRate, spansBeats: beatsPerTemplate)
        }

        // Fold the signal into segments of foldSamples length and average them
        let numFolds = samples.count / foldSamples
        guard numFolds > 0 else {
            return TickTemplate(samples: [0], sampleRate: sampleRate, spansBeats: beatsPerTemplate)
        }

        var template = [Float](repeating: 0, count: foldSamples)

        for fold in 0..<numFolds {
            let offset = fold * foldSamples
            // Accumulate: template += samples[offset..<offset+foldSamples]
            samples.withUnsafeBufferPointer { buf in
                vDSP_vadd(template, 1, buf.baseAddress! + offset, 1, &template, 1, vDSP_Length(foldSamples))
            }
        }

        // Divide by number of folds to get the average
        var divisor = Float(numFolds)
        vDSP_vsdiv(template, 1, &divisor, &template, 1, vDSP_Length(foldSamples))

        // Normalize to unit energy
        var energy: Float = 0
        vDSP_dotpr(template, 1, template, 1, &energy, vDSP_Length(foldSamples))
        if energy > 0 {
            var scale = 1.0 / sqrt(energy)
            vDSP_vsmul(template, 1, &scale, &template, 1, vDSP_Length(foldSamples))
        }

        return TickTemplate(samples: template, sampleRate: sampleRate, spansBeats: beatsPerTemplate)
    }
}
