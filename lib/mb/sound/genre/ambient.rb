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

      # Loops in seconds (Eno's incommensurable tape loops): whole notes at
      # 60 BPM are 4 s, so 19.7 s is 197/40 whole notes.  Bowls and rin
      # stay in every scene once they start, so their loops keep turning.
      clip :drone, events([0, 16, D2, 0.7], length: 16, loop: true)
      clip :bowl_a, events([0, 1/8r, D4, 0.8], length: 197/40r, loop: true)
      clip :bowl_b, events([0, 1/8r, A3, 0.7], length: 233/40r, loop: true)
      clip :rin, events([0, 1/16r, E5, 0.6], length: 311/40r, loop: true)
      clip :gong, seq(D2).n1
      clip :motif, seq(
        A4, R, R, D5, R, B4, R, R,   R, R, E5.maybe(0.6), R, R, R, R, R,
        G4, R, R, A4, R, R, R, R,    R, D5, R, R, B4.maybe(0.5), R, R, R,
      ).n8.humanize(1.n64, velocity: 0.15).loop(align: :launch)
      clip :harp, seq(D5, R, A4, B4.maybe(0.7), R, D5, R, E5, R, G4, R, R, A4.maybe(0.5), R, R, R).n16.swing(0.6).loop(align: :launch)
      clip :stick, seq(D5, T, T).n1

      knob :dusk, 9000, range: 300..12000, curve: :exp, unit: 'Hz'

      role :drone, :ambient_drone, about: 'two sine generators drifting against each other on the root and fifth'
      role :bowls, :ambient_bowl, about: 'singing bowl strikes, every partial a beating doublet'
      role :bowls2, :ambient_bowl, about: 'a second bowl on its own loop length'
      role :rin, :ambient_rin, about: 'a small rin, the still point'
      role :gong, :ambient_gong, level: -3.db, about: 'a tam-tam stroke whose shimmer blooms over seconds'
      role :motif, :ambient_koto, filter: :dusk, about: 'a sparse FM koto motif, humanized, some notes by chance'
      role :harp, :ambient_harp, filter: :dusk, level: -2.db, about: 'a swung Karplus-Strong figure'
      role :stick, :ambient_rainstick, level: -4.db, about: 'a rain stick tipping across'

      scene :emerge, drone: :drone, dusk: 9000
      scene :drift, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b
      scene :bloom, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b, gong: :gong, motif: :motif, harp: :harp
      scene :hush, bowls: :bowl_a, bowls2: :bowl_b, rin: :rin
      scene :tide, drone: :drone, bowls: :bowl_a, bowls2: :bowl_b, rin: :rin, stick: :stick, gong: :gong, motif: :motif, harp: :harp
      scene :dissolve, bowls: :bowl_a, bowls2: :bowl_b, rin: :rin, motif: :motif, harp: :harp, dusk: [600, { over: 4, curve: :smooth }]

      loudness(-19..-16)
      true_peak(-1.db)
      master :at, 4.db
      master :limit, ceiling: -1.db
      master_gain 0.db

      tip 'No verse and chorus: an arch or a tide (emerge, bloom, a still point, return, dissolve).  Most pieces run 6-60 minutes; a scene can hold for minutes.'
      tip 'Loops of incommensurable lengths in seconds (19.7, 23.3, 31.1 s) never line up the same way twice: the phase drift is the composition.  Keep such tracks in every scene so they keep turning (dropping a track and bringing it back restarts its loop).'
      tip 'Silence is an instrument: few notes, wide gaps, a pentatonic or modal set (here the yo scale: D E G A B), drones on the root and fifth.'
      tip 'Protect tails: long rooms with pre-delay and damping, and let the form ring everything out at the end.'
      tip 'Master quiet (-16 to -18 LUFS, -1 dBTP; a limiter as a safety, not a sound); a loudness range of 8-15 LU is normal.  Rain, water, and other textures are filtered noise and pinged drops (see bin/songs/tin_roof.rb).'
    end
  end
end
