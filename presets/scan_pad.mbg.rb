# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "scan_pad",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Wavetable pad: a table from a sine through hollow, vocal, and bright frames to a saw, scanned forward by a slow envelope on each note and back and forth by an LFO (wavetable scanning; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:wavetable, :scan, :pad, :evolving],
  options: { patch: :scan_pad }
inputs midi: :notes
param :scan, (0.0..1.0).at(0.2), description: "Table position at the start of a note (0 sine .. 1 saw)"
param :sweep, (-1.0..1.0).at(0.5), description: "How far the envelope scans over swell seconds"
param :swell, (0.01..10.0).at(3.0), description: "Seconds the envelope takes to scan"
param :wobble, (0.0..0.5).at(0.12), description: "LFO scan depth"
param :rate, (0.01..8.0).at(0.25), description: "LFO rate in Hz"
param :release, (0.01..8.0).at(1.2), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  fx = (scan + sweep * v.env(swell, 0, 1, release, gm: false).no_velocity + wobble * rate.tone.sine.lfo).aclip(0, 1)
  sig = v.hz
  (sig.wavetable(wavetable_of(:sine, [1, 0, 0.45, 0, 0.25, 0, 0.12, 0, 0.06], [0.502, 0.265, 0.251, 0.419, 0.723, 0.883, 0.694, 0.357, 0.14, 0.065, 0.047, 0.042, 0.038, 0.036, 0.033, 0.031, 0.029, 0.028, 0.026, 0.025, 0.024, 0.023, 0.022, 0.021], [1.0, 0.7, 0.333, 0.35, 0.2, 0.233, 0.143, 0.175, 0.111, 0.14, 0.091, 0.117, 0.077, 0.1, 0.067, 0.088, 0.059, 0.078, 0.053, 0.07, 0.048, 0.064, 0.043, 0.058, 0.04, 0.054, 0.037, 0.05, 0.034, 0.047, 0.032, 0.044], :saw, normalize: :loudness), scan: fx) + sig.transpose(0.1).wavetable(wavetable_of(:sine, [1, 0, 0.45, 0, 0.25, 0, 0.12, 0, 0.06], [0.502, 0.265, 0.251, 0.419, 0.723, 0.883, 0.694, 0.357, 0.14, 0.065, 0.047, 0.042, 0.038, 0.036, 0.033, 0.031, 0.029, 0.028, 0.026, 0.025, 0.024, 0.023, 0.022, 0.021], [1.0, 0.7, 0.333, 0.35, 0.2, 0.233, 0.143, 0.175, 0.111, 0.14, 0.091, 0.117, 0.077, 0.1, 0.067, 0.088, 0.059, 0.078, 0.053, 0.07, 0.048, 0.064, 0.043, 0.058, 0.04, 0.054, 0.037, 0.05, 0.034, 0.047, 0.032, 0.044], :saw, normalize: :loudness), scan: fx)) * 0.5 * v.env(0.4, 0.8, 0.8, release, gm: false) * 0.4
}
