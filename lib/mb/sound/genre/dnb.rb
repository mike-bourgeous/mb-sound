module MB
  module Sound
    # Modern UK drum & bass, from the persona panel (2026-10-13): Kez Volta's
    # research (research-persona-edm, research/persona-panel/edm/research.md)
    # and "Tunnel Vision" (bin/songs/tunnel_vision.rb, patches in
    # bin/synths/dnb.rb and presets/dnb_*.mbg.rb).
    Genre.define :dnb, 'Drum & bass (modern UK)' do
      about 'A DJ-friendly roller: two-step drums, a Reese over a separate mono sub, ' \
            'a breakdown of minor 9th pads and a liquid pluck, a switch-up second drop.  ' \
            'From Kez Volta ("Tunnel Vision") in the persona panel of 2026-10-13.'
      tempo 174, range: 170..176
      meter 4, 4
      phrases 8, 16, 32
      key :minor, :f

      flow do
        fill :roll, every: 16
        intro     32
        build     8, fill: [:riser, 4]
        drop      32
        breakdown 15, fill: [:riser, 8]
        pullup    1
        drop2     32
        outro     32
      end
      # A generated form (G4, generative-g4): the same sections as a
      # stochastic L-system, so each seed grows another DJ-friendly roller:
      # one to three build-drop cycles, each drop turning through a
      # breakdown and pull-up into the next (phrases stay on 8 and 16 bars:
      # breakdowns of 7 or 15 plus the pull-up bar).
      # `genre(:dnb).generative(seed: 3).play`
      generator lsystem(%i[intro body outro],
                        body: { %i[build drop turn body] => 2, %i[build drop turn] => 1 },
                        turn: { %i[breakdown pullup drop2] => 2, %i[breakdown pullup drop] => 1 },
                        generations: 3, seed: 174),
                bars: { intro: [16, 32], build: 8, drop: [16, 32], breakdown: [7, 15], pullup: 1, drop2: [16, 32], outro: [16, 32] }

      two_step = 'X.........X.....'
      hats = '7.4.7.4.7.4.7.45'
      shaker = '3524352435243524'
      ghosts = '....X..2.2..X..2'
      roll = { snare: grid(16, '2.3.4.5.5656778X') }
      kit :intro, grid(16, kick: two_step, rim: '....6.......6...', hat: hats, shaker: shaker).loop(align: :launch)
      kit :build, grid(16, kick: two_step, snare: ghosts, hat: hats, open_hat: '..5...5...5...5.').loop(align: :launch)
        .nofill(:snare, name: :roll).fill(:roll, **roll)
      kit :drop, grid(16, kick: two_step, snare: ghosts, clap: '....X.......X...', hat: hats, open_hat: '..4.......4.....', shaker: shaker).loop(align: :launch)
        .nofill(:snare, :clap, name: :roll).fill(:roll, **roll)
      kit :breakdown, grid(16, hat: '4.2.4.2.4.2.4.2.', shaker: shaker).loop(align: :launch)
      kit :drop2, grid(16, kick: two_step + 'X.........X..x..', snare: '....X.2..2..X.2.....X..2.2.2X..3', clap: '....X.......X...', hat: hats).loop(align: :launch)
        .nofill(:snare, :clap, name: :roll).fill(:roll, **roll)
      kit :outro, grid(16, kick: two_step, snare: '....X.......X...', hat: hats, shaker: shaker).loop(align: :launch)

      clip :riff, seq(
        F1, T, T, T, T, T, R, F1, T, R, Ab1, T, F1, T, R, R,
        F1, T, T, T, T, T, R, C2, T, R, Bb1, T, Ab1, T, Eb1, T,
      ).n16.loop(align: :launch)
      clip :neuro, seq(
        F1, R, F1, F1, R, F1, R, F1, T, R, Ab1, R, F1, F1, R, Eb1,
        F1, R, F1, F1, R, F1, R, C2, T, R, Bb1, Ab1, R, Ab1, Eb1, T,
      ).n16.loop(align: :launch)
      clip :chords, seq(F2.n1, Db2.n1, Bb1.n1, C2.n1).bake(chord(0, 7, 15, 19, 26)).legato(0.97).loop(align: :launch)
      clip :pluck, seq(C5, Ab4, F4, Eb5, R, C5, Ab4, G4).n8.loop(align: :launch)
      clip :hit, seq(F1, R, R, R, R, R, R, R).n1.loop(align: :launch)
      clip :bar, seq(R).n1.loop
      # The ghost-kick pump as an option (duck-keys, 2026-10-18): a key
      # line on the two-step under every scene, heard only by the ducks
      # (`genre(:dnb) { sidechain :pump, :pump }`); the default keys from
      # the drums' own kick
      clip :pump, grid(16, two_step).loop(align: :launch)

      knob :cut, (150.hz..8000.hz).at(2400.hz)   # the Reese lowpass
      knob :grit, 0.25, range: 0.0..1.0                                # the neuro crusher's wet share
      knob :space, 0.4, range: 0.0..1.0                                # the pluck's delay send
      knob :air, (20.hz..400.hz).at(20.hz)       # the master highpass

      # (levels and master drive rebalanced in patches-5, 2026-10-13, so the
      # master's limiter only catches peaks: the maintainer heard the mix
      # shift when the neuro stopped; before: drums 0, bass 0, sub -6, neuro
      # -1.5 dB, drive 11 dB, -7.5 LUFS, the clipper and limiter holding
      # drop2 7.1 dB down (median of 100 ms peaks) and the outro 3.9)
      # (genre-fixes, 2026-10-18: the ducks key from the drums track's own
      # kick voice, `duck(:drums, only: :kick)`, so only kicks that play
      # duck (Kez: "Every ducked part building its own ghost kick?  That's
      # not sidechain, that's cosplay"); before, a ghost 808 kick played the
      # drop kit's kick row under every scene.  A little of every track but
      # the sub goes to a :hall bus, as in Tunnel Vision's bus version.)
      role :drums, :dnb_drums, level: -1.db, send: { hall: -24.db }, about: 'two-step 808 kit at DnB tunings, parallel compression'
      role :bass, :dnb_reese, params: { cutoff: :cut }, level: -2.db, duck: -8.db, send: { hall: -20.db }, about: 'the Reese: detuned saws, highpassed off the sub'
      role :sub, :dnb_sub, level: -9.db, duck: -12.db, about: 'a clean mono sine an octave down'
      role :neuro, :dnb_neuro, params: { grit: :grit }, level: -5.5.db, duck: -8.db, send: { hall: -20.db }, about: 'the switch-up bass for drop 2'
      role :pad, :dnb_pad, level: -4.5.db, about: 'minor 9th pads'
      role :pluck, :dnb_pluck, params: { echo: :space }, level: -7.db, about: 'liquid pluck with a dotted-eighth delay'
      role :impact, :dnb_boom, send: { hall: -20.db }, about: 'a falling sine hit on the downbeat'
      role :riser, :riser, params: { bars: 4 }, fade: 1/8r, send: { hall: -18.db }, about: 'noise riser (a fill scene)'

      sidechain :drums, only: :kick
      # The hall: highpassed so the kick's body stays out, wet only, ducked
      # by the sidechain (the kick; the pump with `sidechain :pump, :pump`)
      # (Tunnel Vision's :hall bus without its tail lift)
      bus :hall, [:filter, :highpass, { cutoff: 250, quality: 0.7 }], [:reverb, :hall, { mix: 1 }], [:at, 12.db],
          [:duck, :sidechain, { amount: -6.db, release: 1.n8 }]

      scene :intro, drums: :intro, pad: :chords, cut: 250, air: 20
      scene :build, drums: :build, bass: :riff, cut: [2500, { from: 250, over: 8, curve: :smooth }]
      scene :drop, drums: :drop, bass: :riff, sub: :riff, impact: :hit, cut: 2400, air: 20
      scene :breakdown, drums: :breakdown, pad: :chords, pluck: :pluck, air: [180, { over: 1.beat }]
      scene :pullup, riser: :bar
      scene :drop2, drums: :drop2, neuro: :neuro, sub: :riff, impact: :hit, air: 20, grit: [0.6, { over: 8 }]
      scene :outro, drums: :outro, sub: :riff
      scene :riser, riser: :bar, others: :keep

      loudness(-10..-8)
      true_peak(-0.5.db)
      mono_below 120 # club systems: a mono low end (and the sub is mono already)
      measure :loudest, bars: 16 # the club master targets the loudest phrase (maintainer, omnibus9 Bench: "Dnb 16")
      # (the air knob's highpass, then the club mastering preset with two
      # limiters: mastering-2, 2026-10-17, the maintainer's Bench pick over
      # dnb_master's clip and limit)
      master :filter, :highpass, cutoff: :air, quality: 0.7
      master :club
      master_gain 0.db

      tip 'Sections come in 8s; phrases in 16 and 32.  DJs want a 32-bar intro of drums and light elements, and the drop on a 32-bar line.'
      tip 'The two-step: kick on 1 and on the "and" of 3, snares on 2 and 4, ghost snares between; a snare-roll fill at the end of every 16 tells the crowd something is coming.'
      tip 'Keep the sub a separate clean mono sine below about 100-120 Hz and highpass the Reese above it, so phase wobble never cancels the low end; duck both under the kick.'
      tip 'Tension: a filter build (turn :cut), a riser, and a one-bar pull-up of near silence before the drop; the second drop is a variation (a switch-up bass), not a copy.'
      tip 'For a steady pump that ignores the drum pattern (the hats-only breakdown too), key the ducks from a line nobody hears: genre(:dnb) { sidechain :pump, :pump } plays the two-step as a trigger track under every scene.'
      tip 'Club masters are loud (drops around -6 LUFS short-term, crest factor 6-8 dB): glue, softclip, then a true-peak limiter (clip, then limit).  Balance the parts first: if the limiter holds the whole drop down, the mix shifts when a part stops (turn the drive up only once the balance holds).'
    end
  end
end
