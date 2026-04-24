import Foundation
import WatchBeatCore

// Generate an SVG with one timegraph panel per candidate beat rate so the
// real tick/tock pattern at each rate can be inspected visually.
//
//   Usage: TimegraphPlot <file.wav> [out.svg]

guard CommandLine.arguments.count >= 2 else {
    print("usage: TimegraphPlot <file.wav> [out.svg]")
    exit(1)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
guard let buffer = try? WAVReader.read(url: url) else {
    print("failed to read \(path)")
    exit(1)
}

let outPath: String = CommandLine.arguments.count >= 3
    ? CommandLine.arguments[2]
    : url.deletingPathExtension().appendingPathExtension("timegraph.svg").path

let pipeline = MeasurementPipeline()

let rates: [StandardBeatRate] = StandardBeatRate.allCases
let winner = pipeline.measure(buffer).snappedRate

struct Panel {
    let rate: StandardBeatRate
    let quality: Int
    let rateErr: Double
    let beatErr: Double?
    let timings: [TickTiming]
    let evenOneSided: Double
    let oddOneSided: Double
    let isWinner: Bool
}

func oneSided(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let pos = xs.filter { $0 > 0 }.count
    let frac = Double(pos) / Double(xs.count)
    return max(frac, 1 - frac)
}

var panels: [Panel] = []
for r in rates {
    let res = pipeline.measure(buffer, knownRate: r)
    let ev = res.tickTimings.filter { $0.isEvenBeat }.map { $0.residualMs }
    let od = res.tickTimings.filter { !$0.isEvenBeat }.map { $0.residualMs }
    panels.append(Panel(
        rate: r,
        quality: Int(res.qualityScore * 100),
        rateErr: res.rateErrorSecondsPerDay,
        beatErr: res.beatErrorMilliseconds,
        timings: res.tickTimings,
        evenOneSided: oneSided(ev),
        oddOneSided: oneSided(od),
        isWinner: r == winner
    ))
}

// Shared y-axis domain: clip to ±half-period of the lowest-bph rate so all
// panels share scale and outliers don't compress everything. Use a generous
// but common range.
let yClamp = 20.0  // ms
let cols = 2
let rows = (panels.count + cols - 1) / cols
let panelW = 520.0
let panelH = 220.0
let mLeft = 52.0, mRight = 14.0, mTop = 42.0, mBot = 36.0
let plotW = panelW - mLeft - mRight
let plotH = panelH - mTop - mBot
let totalW = panelW * Double(cols)
let totalH = panelH * Double(rows) + 48  // header

var svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="\(Int(totalW))" height="\(Int(totalH))" viewBox="0 0 \(Int(totalW)) \(Int(totalH))" font-family="-apple-system, Helvetica, sans-serif">
<rect width="100%" height="100%" fill="#ffffff"/>
<text x="12" y="28" font-size="17" font-weight="600">\(url.lastPathComponent)  —  timegraph per candidate rate (residual vs beat index)</text>

"""

for (i, p) in panels.enumerated() {
    let col = i % cols
    let row = i / cols
    let x0 = Double(col) * panelW
    let y0 = 48.0 + Double(row) * panelH
    let px0 = x0 + mLeft
    let py0 = y0 + mTop
    let fill = p.isWinner ? "#fff7e0" : "#fafafa"
    svg += "<g>\n"
    svg += "<rect x=\"\(x0+2)\" y=\"\(y0+2)\" width=\"\(panelW-4)\" height=\"\(panelH-4)\" fill=\"\(fill)\" stroke=\"#d0d0d0\"/>\n"

    // Title bar
    let winnerTag = p.isWinner ? "  ◀ WINNER" : ""
    let beatStr = p.beatErr.map { String(format: "%.2f ms", $0) } ?? "—"
    let title = String(format: "%d bph   q=%d%%   rate=%+.1f s/d   beat=%@%@",
                       p.rate.rawValue, p.quality, p.rateErr, beatStr, winnerTag)
    svg += "<text x=\"\(x0+10)\" y=\"\(y0+22)\" font-size=\"13\" font-weight=\"600\">\(title)</text>\n"
    let osTxt = String(format: "EVEN n=%d os=%.2f      ODD n=%d os=%.2f",
                       p.timings.filter{$0.isEvenBeat}.count, p.evenOneSided,
                       p.timings.filter{!$0.isEvenBeat}.count, p.oddOneSided)
    svg += "<text x=\"\(x0+10)\" y=\"\(y0+38)\" font-size=\"11\" fill=\"#555\">\(osTxt)</text>\n"

    // Plot area frame
    svg += "<rect x=\"\(px0)\" y=\"\(py0)\" width=\"\(plotW)\" height=\"\(plotH)\" fill=\"#ffffff\" stroke=\"#b0b0b0\"/>\n"

    // Y axis grid + labels at ±yClamp, ±yClamp/2, 0
    func yPix(_ ms: Double) -> Double {
        let clamped = max(-yClamp, min(yClamp, ms))
        return py0 + plotH * (1 - (clamped + yClamp) / (2 * yClamp))
    }
    for v in [-yClamp, -yClamp/2, 0.0, yClamp/2, yClamp] {
        let y = yPix(v)
        let stroke = (v == 0) ? "#888" : "#ddd"
        let width = (v == 0) ? "1.2" : "0.7"
        svg += "<line x1=\"\(px0)\" y1=\"\(y)\" x2=\"\(px0+plotW)\" y2=\"\(y)\" stroke=\"\(stroke)\" stroke-width=\"\(width)\"/>\n"
        svg += "<text x=\"\(px0-6)\" y=\"\(y+4)\" font-size=\"10\" text-anchor=\"end\" fill=\"#666\">\(String(format: "%+.0f", v))</text>\n"
    }
    svg += "<text x=\"\(px0-32)\" y=\"\(py0+plotH/2-20)\" font-size=\"10\" fill=\"#666\" transform=\"rotate(-90 \(px0-32) \(py0+plotH/2-20))\">residual ms</text>\n"
    svg += "<text x=\"\(px0+plotW/2)\" y=\"\(py0+plotH+22)\" font-size=\"10\" fill=\"#666\" text-anchor=\"middle\">beat index</text>\n"

    // Data points
    let beats = p.timings.map { $0.beatIndex }
    let maxBeat = max(1, beats.max() ?? 1)
    for t in p.timings {
        let x = px0 + plotW * Double(t.beatIndex) / Double(maxBeat)
        let y = yPix(t.residualMs)
        let fillColor = t.isEvenBeat ? "#2c66d8" : "#d84a4a"
        svg += "<circle cx=\"\(String(format: "%.1f", x))\" cy=\"\(String(format: "%.1f", y))\" r=\"2.4\" fill=\"\(fillColor)\" opacity=\"0.85\"/>\n"
    }

    svg += "</g>\n"
}

// Legend
let legY = 48.0 + Double(rows) * panelH - 20
svg += "<g>\n"
svg += "<circle cx=\"14\" cy=\"\(legY)\" r=\"4\" fill=\"#2c66d8\"/><text x=\"24\" y=\"\(legY+4)\" font-size=\"12\">EVEN beat (tick)</text>\n"
svg += "<circle cx=\"138\" cy=\"\(legY)\" r=\"4\" fill=\"#d84a4a\"/><text x=\"148\" y=\"\(legY+4)\" font-size=\"12\">ODD beat (tock)</text>\n"
svg += "<text x=\"260\" y=\"\(legY+4)\" font-size=\"11\" fill=\"#555\">os = fraction on dominant side of zero (1.0 = all same side, 0.5 = split)</text>\n"
svg += "</g>\n"

svg += "</svg>\n"

try? svg.write(toFile: outPath, atomically: true, encoding: .utf8)
print("wrote \(outPath)")
