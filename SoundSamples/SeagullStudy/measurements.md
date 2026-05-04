# Seagull ST3600 Calibration Study — 2026-05-04

11 paired measurements: WatchBeat (iOS app) vs. No. 1000 timegrapher,
taken seconds apart. Watch is a brand-new Seagull ST3600 movement,
caseless. 21,600 bph, lift angle **44°** (per timegrapher display in
shots 5, 6, 9, 10, 11), Dial Down position throughout.

The timegrapher shows extremely stable behavior (+10 to +13 s/day
across all 11 readings, amplitude 232°-241°, BE 0.5 ms — almost
perfectly consistent). This makes it a reliable reference for
calibrating the app.

## Per-recording table

WatchBeat ("App") values are read from the Seagull*N*.PNG screenshots.
Timegrapher ("TG") values are read from the Seagull*N*ref.HEIC photos.

| # | App rate s/d | App BE ms | App amp ° | TG rate s/d | TG amp ° | TG BE ms | Notes |
|---:|---:|---:|---:|---:|---:|---:|---|
|  1 | -26.6 | 0.7 | 184 | +13 | 232 | 0.6 | clean |
|  2 | -27.3 | 0.8 | 186 | +12 | 236 | 0.5 | clean |
|  3 | -31.0 | 0.8 | 203 | +12 | 238 | 0.5 | clean |
|  4 | -29.7 | 0.8 | 196 | +12 | 237 | 0.5 | clean |
|  5 | -28.7 | 0.7 | 186 | +11 | 238 | 0.5 | clean |
|  6 | -31.8 | 0.8 | 191 | +13 | 233 | 0.5 | clean |
|  7 | -31.4 | 0.7 | 192 | +12 | 236 | 0.5 | clean |
|  8 | -32.1 | 0.7 | 181 | +10 | 241 | 0.5 | clean |
|  9 | **-69.4** | 0.7 | 178 | +11 | 240 | 0.5 | **loud-noise contamination** |
| 10 | -27.9 | 0.8 | 182 | +12 | 235 | 0.5 | clean |
| 11 | **+590**  | 0.8 | 198 | +12 | 236 | 0.5 | **loud-noise contamination** |

## Derived: App − TG (the offsets)

| # | Rate offset s/d | Amp offset ° | BE offset ms |
|---:|---:|---:|---:|
|  1 | -39.6 | -48 | +0.1 |
|  2 | -39.3 | -50 | +0.3 |
|  3 | -43.0 | -35 | +0.3 |
|  4 | -41.7 | -41 | +0.3 |
|  5 | -39.7 | -52 | +0.2 |
|  6 | -44.8 | -42 | +0.3 |
|  7 | -43.4 | -44 | +0.2 |
|  8 | -42.1 | -60 | +0.2 |
|  9 | **-80.4** | -62 | +0.2 |
| 10 | -39.9 | -53 | +0.3 |
| 11 | **+578**  | -38 | +0.3 |

## Summary statistics (clean rows only — 1-8, 10)

| Metric | n | Mean | Min | Max | Spread |
|---|---:|---:|---:|---:|---:|
| Rate offset (App − TG)         | 9 | **-41.5 s/d** | -44.8 | -39.3 | 5.5 s/d |
| App rate alone                 | 9 | -29.7 s/d | -32.1 | -26.6 | 5.5 s/d |
| TG rate alone                  | 9 | +11.8 s/d | +10   | +13   | 3 s/d |
| Amp offset (App − TG)          | 9 | **-47°**   | -60   | -35   | 25°    |
| App amp alone                  | 9 | 189° | 181 | 203 | 22° |
| TG amp alone                   | 9 | 236° | 232 | 241 |  9° |
| BE offset (App − TG)           | 9 | **+0.24 ms** | +0.1 | +0.3 | 0.2 ms |
| App BE alone                   | 9 | 0.76 ms | 0.7 | 0.8 | 0.1 ms |
| TG BE alone                    | 9 | 0.52 ms | 0.5 | 0.6 | 0.1 ms |

## Three observations

### 1. Rate offset is highly consistent (excluding noise-contaminated)

The clean 9 readings show **App reads −41.5 ± 2.7 s/day relative to the
timegrapher**. Spread is only 5.5 s/day across 8 minutes of recordings.
This looks like a reproducible per-device calibration offset (probably
iPhone audio ADC clock drift), not a picker bug.

41.5 s/day = 480 ppm. High for an iPhone audio crystal but not
implausible — especially with thermal effects during sustained
recording. **The fix would be a per-device calibration offset stored
in user settings, ideally derived from an NTP-synced wall-clock
reference.**

### 2. Amplitude offset is also consistent — App reads ~47° low

App: 181-203° (mean 189°) vs TG: 232-241° (mean 236°). Spread on the
app side (22°) is much wider than the timegrapher (9°), so individual
readings are noisier as well as biased.

This is the **pulse-width vs. sub-event-spacing** disagreement we
discussed previously. Swiss escapements have multi-event ticks (lock /
impulse / drop within ~5 ms); the app's 20%-threshold pulse-width
catches all three as one wide pulse → reports too-wide pulse →
amplitude reads low. Industry timegraphers use sub-event SPACING.

The per-class FFT-amplitude prototype Tim already built uses sub-event
spacing — this study is the ground truth needed to validate it.

### 3. Beat error agreement is good (App ~0.2 ms higher consistently)

App 0.7-0.8 ms vs TG 0.5 ms. Small systematic bias of ~0.2 ms but very
consistent. Acceptable. Useful sanity check that the per-tick timing
relationship is being read correctly even when absolute rate is off.

## Noise contamination — Seagull9 and Seagull11

Both have rate readings that depart radically from the offset baseline:
- Seagull9: rate offset -80.4 s/d (would have been ~-41 if clean)
- Seagull11: rate offset +578 s/d (huge positive excursion)

Tim's note: these recordings included a few isolated loud noises. Both
still passed the routing gates and displayed on the result page with
plausible-looking timegraphs. **The picker is extremely sensitive to
isolated loud impulses** — they bias the slope significantly.

Beat error and amplitude on these contaminated readings stayed within
the normal range (BE 0.7-0.8, amp 178-198), so those pieces of the
algorithm are robust to the impulses. Only rate is hurt.

This is a high-priority target for algorithm improvement: defend
against isolated loud transients without sacrificing real-tick
detection.

## Calibration plan implications

- **Rate**: per-device offset, calibrate against NTP. Tim noted he can
  provide more info on NTP-based calibration. Once offset is known,
  subtract from all reported rates. Should bring app readings in line
  with timegrapher.

- **Amplitude**: switch to sub-event-spacing method (the per-class FFT
  prototype). Tune against this study's TG values as ground truth.

- **Robustness**: investigate impulse-rejection in the Reference picker.
  Possible: pre-filter for transient outliers in the energy envelope
  before per-window argmax, or downweight windows with energy >> the
  typical tick energy.
