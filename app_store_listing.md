# WatchBeat — App Store Listing Copy

Drafts of every field you'll fill in on App Store Connect. Each section
header indicates which field the text below it belongs to. The text
itself is plain — copy-paste directly into the form.


## Name

WatchBeat — Watch Timegrapher


## Promotional Text (170 char max — can be updated anytime without a new version)

Measure your mechanical watch's accuracy with the iPhone microphone. Get rate, beat error, and amplitude — no extra hardware needed.


## Description (4000 char max)

WatchBeat turns your iPhone into a mechanical watch timegrapher. Hold the watch close to the iPhone microphone, tap Measure, and see your watch's accuracy in seconds — no clamps, no probes, no extra hardware.

WHAT YOU GET

• Rate accuracy in seconds per day, with FAST/SLOW indication
• Beat error in milliseconds (the timing asymmetry between tick and tock)
• Amplitude — the angular swing of the balance wheel
• A timegraph showing every detected tick across a 15-second analysis window
• Recording quality and confidence indicators so you know how much to trust each reading

ADVANCED DSP MAKES THE DIFFERENCE

Mechanical watches are quiet, and the iPhone microphone is general-purpose. WatchBeat's signal processing was built specifically for this challenge:

• Aggressive impulse rejection cleans up isolated transients (chair scrapes, fingernail flicks, phone bumps) without disturbing real ticks
• Per-class outlier rejection drops noise picks before they bias the rate calculation
• Sub-event spacing measurement — the same physical principle commercial timegraphers use — gives amplitude readings that match dedicated hardware on watches across the spectrum from modern Swiss automatics to vintage pin-lever movements
• Calibrated against a dedicated hardware timegrapher: agreement is within ±2 seconds per day on rate, ±0.2 ms on beat error, and ±5° on amplitude when the watch isn't excessively erratic

WatchBeat shows ticks for a processed 15-second window — not as they come in. Other apps show ticks live; WatchBeat sacrifices the live display to give you a meaningfully more accurate result from the same recording time.

HOW TO USE

1. Hold the watch close to your iPhone's microphone — anywhere works. For automatic position recognition (dial-up, crown-down, etc.), press the watch caseback against the bottom edge of the iPhone with the crown pointing left.
2. Tap Listen, then Measure when ready.
3. Hold still for 15 seconds. Read the result.

SUPPORTS ALL COMMON BEAT RATES

18,000 / 19,800 / 21,600 / 25,200 / 28,800 / 36,000 bph — covering virtually all mechanical watches from vintage pin-lever to modern high-beat automatics. Works on any mechanical watch (hand-wound or automatic). Quartz watches are not supported — they tick at 1 Hz, which conflicts with the resting human heart rate and isn't a useful signal.

LIFT ANGLE

Enter your watch caliber's lift angle on the result screen for accurate amplitude. Common values are documented in-app — tap the (i) icons for guidance. Default is 50°, which is correct for most modern Swiss automatics (ETA 2824, Sellita SW200, Omega 8500/8800, Rolex 3135).

WHEN TO USE

• Check a recent service: see if amplitude returned to expected range
• Compare positions: dial-up vs crown-down, see how a watch behaves
• Quick sanity-check before sending a watch in for service
• Track a watch's accuracy over time

WHAT IT'S NOT

WatchBeat isn't a substitute for a watchmaker. It tells you what the watch is doing, not whether it needs service or what the underlying issue is. Use it as a tool, not a verdict.

PRIVACY

WatchBeat does all signal processing on-device. Microphone audio is never saved to disk, never transmitted off your device, and never shared with anyone. Motion data (used only for detecting watch position during measurement) is also processed locally and never leaves your phone.


## Keywords (100 char max, comma-separated)

watch,timegrapher,mechanical,accuracy,rate,beat error,amplitude,horology,bph,tick


## Support URL

https://github.com/timgulden/WatchBeat


## Marketing URL (optional)

(leave blank — or use the same GitHub URL)


## Copyright

© 2026 Tim Gulden


## Category

Primary: Utilities
Secondary: (leave blank, or pick "Tools" if Apple offers it)


## Age Rating

4+ (the questionnaire will land here automatically — no objectionable content, no data collection, no in-app purchases, no ads)


## App Review Information — Notes

WatchBeat measures the timing accuracy of mechanical (hand-wound or automatic) wristwatches and pocket watches using the iPhone microphone. It does not work on quartz watches.

To test: bring any mechanical watch (most analog watches with a sweeping second hand are mechanical; battery-powered analog watches and digital watches are not) close to the iPhone microphone. The bottom edge of the iPhone is the best position. Tap Listen, then Measure. After 15 seconds, the app displays the watch's beat rate (in beats per hour), rate accuracy (in seconds per day), beat error (in ms), and balance amplitude (in degrees).

If a mechanical watch isn't readily available, the app can also detect a kitchen wall clock or any periodic mechanical click in the 5–10 Hz range. The displayed rate won't be meaningful for non-watch sources but the app will not crash or malfunction.

No login, no in-app purchase, no network usage. All processing is on-device.
