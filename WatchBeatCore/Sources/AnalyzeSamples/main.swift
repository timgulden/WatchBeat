import Foundation
import Accelerate
import WatchBeatCore

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let files = try FileManager.default.contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".wav") }
    .sorted()

guard !files.isEmpty else { print("No WAV files"); exit(1) }

// Simplified tick extraction with configurable window
func testWindow(samples: [Float], sr: Double, windowFrac: Double) -> (ticks: Int, quality: Int, error: Int) {
    let rate = StandardBeatRate.bph21600
    let period = rate.nominalPeriodSeconds
    let ps = Int(round(period * sr))
    let n = samples.count
    guard ps > 10 && ps < n / 3 else { return (0, 0, 0) }

    var sq = [Float](repeating: 0, count: n)
    vDSP_vsq(samples, 1, &sq, 1, vDSP_Length(n))

    let tw = max(10, Int(Double(ps) * windowFrac))
    let ht = tw / 2

    var bestT = 0; var bestQ = 0.0; var bestE = 0.0
    for k in 0..<5 {
        let off = k * ps / 5
        let nw = (n - off) / ps
        guard nw >= 3 else { continue }

        var po = [Int]()
        for w in 0..<nw {
            let ws = off + w * ps
            var bi = 0; var bv: Float = 0
            for i in 0..<ps { if sq[ws+i] > bv { bv = sq[ws+i]; bi = i } }
            po.append(bi)
        }
        let mo = po.sorted()[po.count/2]

        var te = [Float](); var ge = [Float](); var pt = [Double]()
        for w in 0..<nw {
            let c = off + w*ps + mo
            guard c >= ht && c+ht < n else { continue }
            let ws = c - ht
            var e: Float = 0
            for i in 0..<tw { e += sq[ws+i] }
            te.append(e)
            var pi = 0; var pv: Float = 0
            for i in 0..<tw { if sq[ws+i] > pv { pv = sq[ws+i]; pi = i } }
            let ai = ws + pi
            if ai > 0 && ai < n-1 {
                let a=sq[ai-1],b=sq[ai],c2=sq[ai+1]; let d=a-2*b+c2
                let o2: Float = abs(d)>1e-15 ? 0.5*(a-c2)/d : 0
                pt.append((Double(ai)+Double(o2))/sr)
            } else { pt.append(Double(ai)/sr) }
            let gc = c + ps/2
            if gc >= ht && gc+ht < n {
                var g: Float = 0; let gs = gc-ht
                for i in 0..<tw { g += sq[gs+i] }
                ge.append(g)
            }
        }
        guard te.count >= 3 else { continue }
        let mg = ge.sorted()[ge.count/2]
        var cf = [Int]()
        for i in 0..<te.count { if te[i] > mg*2 || mg == 0 { cf.append(i) } }
        guard cf.count >= 3 else { continue }
        let mt = te.sorted()[te.count/2]
        let snr = mg > 0 ? Double(mt/mg) : 100
        let q = min(1, max(0, 1-exp(-snr/5)))
        var sx=0.0,sy=0.0,sxy=0.0,sxx=0.0,cnt=0.0
        for i in cf { guard i<pt.count else{continue}; let x=Double(i),y=pt[i]; sx+=x;sy+=y;sxy+=x*y;sxx+=x*x;cnt+=1 }
        let dn = cnt*sxx-sx*sx
        guard abs(dn)>1e-20 && cnt>=3 else{continue}
        let slope = (cnt*sxy-sx*sy)/dn
        guard abs(slope-period)/period < 0.02 else{continue}
        let err = (period-slope)/period*86400
        if cf.count > bestT { bestT=cf.count; bestQ=q; bestE=err }
    }
    return (bestT, Int(bestQ*100), Int(bestE))
}

print("=== w20 vs w40 on 15-second segments ===\n")

var w20pass = 0; var w40pass = 0; var total = 0

func processFile(_ filename: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
    guard let buffer = try? WAVReader.read(url: url) else { return }
    let raw = buffer.samples
    let sr = buffer.sampleRate
    let short = String(filename.dropFirst(10).dropLast(4))
    let seg15 = Int(15 * sr)

    let starts = [0, Int(7.5*sr), Int(15*sr)]
    let names = ["first15", "mid15  ", "last15 "]

    for (i, s) in starts.enumerated() {
        let e = min(s + seg15, raw.count)
        guard e - s > seg15/2 else { continue }
        let slice = Array(raw[s..<e])

        let r20 = testWindow(samples: slice, sr: sr, windowFrac: 0.2)
        let r40 = testWindow(samples: slice, sr: sr, windowFrac: 0.4)
        total += 1
        if r20.quality >= 30 { w20pass += 1 }
        if r40.quality >= 30 { w40pass += 1 }

        let t20 = r20.quality >= 30 ? "OK" : "xx"
        let t40 = r40.quality >= 30 ? "OK" : "xx"
        print("\(short) \(names[i])  w20:\(r20.quality)% \(t20) e=\(r20.error)  w40:\(r40.quality)% \(t40) e=\(r40.error)")
    }
}

for f in files { processFile(f) }
print("\nAbove 30%:  w20: \(w20pass)/\(total)  w40: \(w40pass)/\(total)")
