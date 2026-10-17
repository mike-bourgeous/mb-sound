module MB
  module Sound
    # Techno (a stub from general knowledge, not from the persona panel):
    # four on the floor at 132, a rolling bass, a filtered stab, on the
    # tr909.
    Genre.define :techno, 'Techno (stub)' do
      about 'A stub from general knowledge (not researched by the panel): a driving four on the floor, ' \
            '16th hats, a rolling offbeat bass, one stab opening up over long phrases, on a TR-909.'
      tempo 132, range: 125..140
      meter 4, 4
      phrases 16, 32
      key :minor, :f

      flow do
        intro     32
        build     16
        peak      32
        breakdown 16
        peak2     32
        outro     32
      end

      four = 'X...X...X...X...'
      kit :intro, grid(16, kick: four, closed_hat: '3535353535353535').loop(align: :launch)
      kit :peak, grid(16, kick: four, clap: '....X.......X...', closed_hat: '3535353535353535', open_hat: '..5...5...5...5.', rimshot: '...3..3....3..3.').loop(align: :launch)
      kit :breakdown, grid(16, closed_hat: '..3...3...3...3.').loop(align: :launch)

      clip :bass, seq(R, F1, F1, R, R, F1, F1, R, R, F1, F1, R, R, F1, Ab1, R).n16.legato(0.5).loop(align: :launch)
      clip :stab, seq(R, R, F3, R, R, R, R, R).n8.bake(chord(0, 3, 7)).loop(align: :launch)

      knob :cut, 400, range: 150..6000, curve: :exp, unit: 'Hz'

      role :drums, :tr909, level: -4.db, about: 'the tr909, the techno kit'
      # (the roller: a short sub with a noise tick in a small room, ducked
      # under the kick, so it rolls between the kicks instead of booming
      # under them; patches-4, 2026-10-13: "clashes with 808 kick"; level
      # +2 dB and duck -4 dB from the maintainer's Bench pick, drums-3)
      role :bass, :roller, level: 2.db, duck: -4.db, about: 'a rolling offbeat sub with a noise tick, ducked under the kick'
      # (Genre::Patches.stab: the Reese's voice with a gentle drive; drums-3,
      # after "an insane amount of distortion on the stab note".  The heavy
      # one: `role :stab, :stab, params: { cutoff: :cut, drive: 1 }`, or the
      # Reese itself, `role :stab, :dnb_reese, params: { cutoff: :cut }`)
      role :stab, :stab, params: { cutoff: :cut }, level: -9.db, about: 'a detuned stab opening over the phrase'

      pulse :peak

      scene :intro, drums: :intro, cut: 400
      scene :build, drums: :intro, bass: :bass, stab: :stab, cut: [1500, { from: 400, over: 16 }]
      scene :peak, drums: :peak, bass: :bass, stab: :stab, cut: 3000
      scene :breakdown, drums: :breakdown, stab: :stab, cut: [600, { over: 4 }]
      scene :peak2, drums: :peak, bass: :bass, stab: :stab, cut: [5000, { from: 1500, over: 16 }]
      scene :outro, drums: :intro, bass: :bass

      loudness(-9..-7)
      true_peak(-0.5.db)
      mono_below 120 # club systems
      # (the club mastering preset with its two limiters, no clipper:
      # mastering-2, 2026-10-17, maintainer on the Bench: "The IMD on some
      # of the stabs is noticeable in the clipping variant"; the
      # limiter-only master before it sat at -11.4 LUFS, 2.4 LU under)
      master :club
      master_gain 0.db

      tip 'A stub: tempo, form, and grids from general knowledge; a later panel should research and refine it.'
      tip 'Long phrases and slow change: one element opens or enters every 16-32 bars; a filter on a stab is a whole section\'s movement.'
      tip 'The kick and the bass share the low end: keep the bass off the kick (offbeats) and mono.'
    end
  end
end
