module MB
  module Sound
    # Live-looped funk / neo-soul, from the persona panel (2026-10-13): Tiko
    # Marvell's research (research-persona-looper,
    # research/persona-panel/looper/research.md) and "Loop Church"
    # (bin/songs/loop_church.rb, patches in bin/synths/funk.rb and
    # presets/funk_*.mbg.rb).
    Genre.define :funk, 'Funk / neo-soul (live looper)' do
      about 'A one-person band built in front of the crowd: two-bar loops layered one at a time ' \
            '(beat, bass, keys, percussion), a talkbox hook over a minor-ninth vamp, a bridge, a peak, ' \
            'then layers muted away.  From Tiko Marvell ("Loop Church") in the persona panel of 2026-10-13.'
      tempo 96, range: 85..110
      meter 4, 4
      phrases 2, 4, 8
      key :dorian, :d

      flow do
        beat   2
        bass   2
        keys   2
        perc   2
        groove 8
        bridge 8
        groove
        peak   8
        strip  4
        outro  4
      end

      clip :beat, grid(16,
        kick:  'X.....X...X..x..' * 2,
        snare: '....X..3.3..X..3' + '.3..X..3....X.3.',
        hat:   '7473747374737473' * 2,
      ).to_clip.swing(0.57).loop(align: :launch)
      clip :perc, grid(16,
        maracas:   '5353535353535353',
        rimshot:   '..3.....3..3....',
        low_conga: '......4.....4...',
        mid_conga: '...4.......4..4.',
      ).to_clip.swing(0.57).loop(align: :launch)

      # Dm9 | G13 (rootless voicings), then the bridge's Bbmaj9 | A7#9
      clip :bass, seq(
        !D2, R, D2, R,  R, C3, R, D2,  R, R, A2, R,  C3, R, D3, R,
        !G1, R, G1, R,  R, F2, R, G1,  R, R, B1, R,  D2, R, E2, F2,
      ).n16.legato(0.7).swing(0.57).loop(align: :launch)
      clip :bass_b, seq(
        !Bb1, R, Bb1, R,  R, F2, R, Bb1,  R, R, D2, R,  F2, R, A2, R,
        !A1, R, A1, R,    R, E2, R, A1,   R, R, Cs2, R, E2, R, G2, R,
      ).n16.legato(0.7).swing(0.57).loop(align: :launch)
      vamp = [[F3, A3, C4, E4], [F3, A3, B3, E4]]
      bridge = [[D3, F3, A3, C4], [Cs3, G3, C4, E4]]
      clip :keys, (0...4).map { |i| seq(*vamp.flat_map { |c| [R, R, c[i], R, R, c[i], R, R] }).n8 }.reduce(:&).legato(0.8).loop(align: :launch)
      clip :keys_b, (0...4).map { |i| seq(*bridge.flat_map { |c| [c[i], R, R, c[i], R, R, c[i], R] }).n8 }.reduce(:&).legato(0.8).loop(align: :launch)
      clip :clav, seq(R, D4, R, F4, R, R, D4, R, R, D4, R, A4, R, C5, R, R).n16.swing(0.57).loop(align: :launch)
      clip :hook, seq(
        A4.n8, C5.n8, D5.n4, R.n8, C5.n16, A4.n16, G4.n4,
        F4.n8, G4.n8, A4.n4.d, R.n4,
      ).loop(align: :launch)

      role :beat, :funk_beat, about: 'mouth-drum kit: an 808 through a formant mouth, kick on the ONE'
      role :perc, :funk_perc, about: 'shaker, rim, and congas overdub'
      role :bass, :funk_bass, about: 'a ghost-noted funk bass'
      role :keys, :funk_keys, about: 'FM electric piano stabs, rootless voicings'
      role :clav, :funk_clav, level: 6.db, about: 'clav stabs (an overdub for the peak)'
      role :lead, :funk_talkbox, level: -5.db, about: 'the talkbox hook, never looped live'

      layers beat: :beat, bass: :bass, keys: :keys, perc: :perc
      scene :groove, beat: :beat, bass: :bass, keys: :keys, perc: :perc, lead: :hook
      scene :bridge, beat: :beat, bass: :bass_b, keys: :keys_b, perc: :perc
      scene :peak, beat: :beat, bass: :bass, keys: :keys, perc: :perc, clav: :clav, lead: :hook
      scene :strip, beat: :beat, bass: :bass
      scene :outro, perc: :perc, keys: :keys

      loudness(-14..-10)
      true_peak(-1.db)
      master :at, 3.5.db
      master :compress, threshold: -16.db, ratio: 2.5, attack: 0.01, release: 0.12, makeup: 2.db
      master :limit, ceiling: -1.db
      master_gain 0.db

      tip 'Build in front of them: rhythm first, then bass, then chords, then the lead that is never looped.  Start with one- or two-bar loops; short loops forgive timing.'
      tip 'Land the ONE hard, then be as syncopated as you like until the next downbeat: ghost notes on bass and snare between the accents, a steady 16th pulse.'
      tip 'The pocket: kick on the grid, snare laid back a few ms, hats loose and swung (about 0.57).  Quantize recorded loops gently, or not at all.'
      tip 'Harmony: two-chord vamps in extended chords (m9, 11, 13, 7#9), rootless voicings, stepwise voice leading, no V-I resolution.'
      tip 'Drop layers instead of only adding (mute groups, one layer every two bars at the end); set levels for the densest moment, and undo on the bar is a performance move.'
    end
  end
end
