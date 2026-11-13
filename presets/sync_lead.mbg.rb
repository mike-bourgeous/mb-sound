# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "sync_lead",
  kind: :synth,
  saved: "2026-11-13T02:06:32Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Hard-sync lead: a saw restarted by the note's cycle, its own pitch swept down from above by an envelope on each note, through a gentle lowpass, with glide and delayed vibrato (hard sync; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:sync, :saw, :lead],
  options: { patch: :sync_lead }
inputs midi: :notes
param :sync, (1.0..8.0).at(1.5), description: "The synced saw's pitch over the note's once the sweep has fallen (1: no sync sound)"
param :sweep, (0.0..8.0).at(3.0), description: "How far above that the sweep starts (in the same ratio units)"
param :sweep_decay, (0.01..5.0).at(0.35), description: "Seconds the sweep takes to fall"
param :cutoff, (200.0..18000.0).at(5000.0), description: "Lowpass cutoff in Hz"
param :glide, (0.0..1.0).at(0.04), description: "Glide between legato notes in seconds"

synth(midi, voices: 1) { |v|
  v.hz.glide(glide, legato: true).vibrato(5.2, depth: 0.15).saw.sync(nil, ratio: sync + sweep * v.env(0.0, sweep_decay, 0, 0.1, gm: false).no_velocity.legato).lp4(cutoff, resonance: 0.1) * v.env(0.004, 0.3, 0.85, 0.12, gm: false).legato * 0.55
}.hp1(20)
