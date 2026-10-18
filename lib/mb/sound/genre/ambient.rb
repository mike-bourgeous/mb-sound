module MB
  module Sound
    # Zen ambient soundscapes, from the persona panel (2026-10-13): Kaede
    # Rowntree's research (research-persona-zen,
    # research/persona-panel/zen/research.md: Eno's tape loops, kankyō
    # ongaku, Hainbach, Four Tet) and "Tin Roof, Slow River"
    # (bin/songs/tin_roof.rb, instruments in bin/synths/ambient.rb and
    # presets/ambient_*.mbg.rb; the rain and river live in the song).
    Genre.define :ambient, 'Ambient (zen soundscape)' do
      about 'An arch with no drums: a drone, singing bowls on loops that never line up, ' \
            'a sparse pentatonic motif with chance notes, gong strokes, a rain stick, a still point of near silence.  ' \
            'From Kaede Rowntree ("Tin Roof, Slow River") in the persona panel of 2026-10-13.'
      tempo 60, range: 50..80
      meter 4, 4
      phrases 4, 8, 16
      key :yo, :d

      flow do
        emerge   8
        drift    16
        bloom    16
        hush     8
        tide     16
        dissolve 8
      end

      # Loops in seconds (Eno's incommensurable tape loops), on clocks of
      # their own (genre-fixes, 2026-10-18, on time-automation's clocks):
      # each clip spans one period of its clock, which counts from the
      # session's start, so a bowl dropped by a scene and brought back
      # comes in where it would have been, and tempo changes don't move it.
      # (Until then: whole notes at 60 BPM, 197/40 for 19.7 s.)
      clip :drone, events([0, 16, D2, 0.7], length: 16, loop: true)
      clip :bowl_a, events([0, 1/8r, D4, 0.8], length: 197/40r, loop: true).clocked(19.7.seconds)
      clip :bowl_b, events([0, 1/8r, A3, 0.7], length: 233/40r, loop: true).clocked(23.3.seconds)
      clip :rin, events([0, 1/16r, E5, 0.6], length: 311/40r, loop: true).clocked(31.1.seconds)
      clip :gong, seq(D2).n1
      # (quarter notes: 8 bars, 32 s, per pass; eighths until 2026-10-13,
      # when the maintainer asked to "slow the koto"; then "maybe half as
      # many notes" (patches-5): about 4 notes per pass, was 7)
      clip :motif, seq(
        A4, R, R, D5, R, R, R, R,    R, R, R, E5.maybe(0.6), R, R, R, R,
        R, R, R, G4, R, R, R, R,     R, R, R, B4.maybe(0.5), R, R, R, R,
      ).n4.humanize(1.n32, velocity: 0.15).loop(align: :launch)
      clip :harp, seq(D5, R, A4, B4.maybe(0.7), R, D5, R, E5, R, G4, R, R, A4.maybe(0.5), R, R, R).n16.swing(0.6).loop(align: :launch)
      clip :stick, seq(D5, T, T).n1
      clip :weather, seq(R).n1.loop # (rain and wind ignore their notes)

      knob :space, 0.5, range: 0..1   # the rooms' level (bowls, rin, gong, koto, harp)
      knob :wear, 0.6, range: 0..1    # how old the tape is (koto, harp; 0.6 like the presets, textures-5)
      knob :shimmer, -7, range: -12..7 # the gong's shimmer tuning in semitones (turn it while a stroke rings)
      knob :spread, 0.7, range: 0..1   # the gong's shimmer width (0 mono, 1 wide)
      knob :drizzle, 0.4, range: 0..1  # how hard it rains (level and density feel)
      knob :gust, 0.5, range: 0..1     # how hard the wind blows

      role :drone, :ambient_drone, about: 'two sine generators drifting against each other on the root and fifth'
      role :bowls, :ambient_bowl, params: { space: :space }, about: 'singing bowl strikes, every partial a beating doublet'
      role :bowls2, :ambient_bowl, params: { space: :space }, about: 'a second bowl on its own loop length'
      role :rin, :ambient_rin, params: { space: :space }, about: 'a small rin, the still point'
      role :gong, :ambient_gong, params: { space: :space, tune: :shimmer, spread: :spread }, level: -3.db, about: 'a tam-tam stroke whose shimmer blooms over seconds'
      role :motif, :ambient_koto, params: { space: :space, wear: :wear }, about: 'a sparse FM koto motif, humanized, some notes by chance'
      role :harp, :ambient_harp, params: { space: :space, wear: :wear }, level: -2.db, about: 'a swung Karplus-Strong figure'
      role :stick, :ambient_rainstick, level: -4.db, about: 'a rain stick tipping across'
      # The weather (genre-fixes, 2026-10-18; Kaede: the rain and river
      # lived in the song, not the template): dust drops and drifting noise
      # into a :weather bus that adds tape hiss gated by the weather
      # sounding (Genre::Patches.hiss), so the hiss stops with the sound
      role :rain, :rain, params: { level: :drizzle }, to: :weather, about: 'rain: dust drops pinging, a pink-noise bed that wanders, slow gusts'
      role :wind, :wind, params: { level: :gust }, to: :weather, about: 'wind: brown noise through a drifting bandpass, in gusts'
      bus :weather, [:hiss]

      scene :emerge, drone: :drone, rain: :weather, space: 0.5, wear: 0.6, drizzle: [0.4, { from: 0, over: 4 }]
      scene :drift, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b, rain: :weather
      scene :bloom, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b, gong: :gong, motif: :motif, harp: :harp, rain: :weather, drizzle: [0.2, { over: 8 }]
      # (the hush drops the second bowl; the tide brings it back in phase)
      scene :hush, bowls: :bowl_a, rin: :rin, wind: :weather, gust: [0.5, { from: 0, over: 4 }]
      scene :tide, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b, rin: :rin, stick: :stick, gong: :gong, motif: :motif, harp: :harp,
                   rain: :weather, wind: :weather, drizzle: [0.7, { over: 8 }], gust: [0.3, { over: 8 }]
      scene :dissolve, bowls: :bowl_a, bowls2: :bowl_b, rin: :rin, motif: :motif, harp: :harp, rain: :weather,
                       wear: [0.7, { over: 4 }], space: [0.8, { over: 4 }], drizzle: [0.1, { over: 8 }]

      loudness(-19..-16)
      true_peak(-1.db)
      master :quiet # (mastering-2, 2026-10-17: the maintainer's Bench pick)
      master_gain 0.db

      tip 'No verse and chorus: an arch or a tide (emerge, bloom, a still point, return, dissolve).  Most pieces run 6-60 minutes.'
      tip 'Hold a scene for minutes: `go :drift` and let it run (or `loop!` inside the flow); the loops in seconds and the weather keep moving, so nothing repeats, and `turn :drizzle, 0.8, over: 16` is a whole section.'
      tip 'Loops of incommensurable lengths in seconds (19.7, 23.3, 31.1 s) never line up the same way twice: the phase drift is the composition.  Put each on its own clock (clip.clocked(19.7.seconds)): it counts from the session start, so a loop dropped by a scene comes back where it would have been.'
      tip 'Silence is an instrument: few notes, wide gaps, a pentatonic or modal set (here the yo scale: D E G A B), drones on the root and fifth.'
      tip 'Protect tails: long rooms with pre-delay and damping, and let the form ring everything out at the end.'
      tip 'Master quiet (-16 to -18 LUFS, -1 dBTP; a limiter as a safety, not a sound); a loudness range of 8-15 LU is normal.  Rain and wind are filtered noise and pinged drops (roles :rain and :wind into the :weather bus, its tape hiss gated by `sounding` so it stops with the weather).'
    end
  end
end
