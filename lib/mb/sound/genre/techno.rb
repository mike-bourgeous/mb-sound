module MB
  module Sound
    # Detroit / peak-time techno for DJs, from Charlie "Munro" Munro's
    # template data (persona panel round 2 sheet, section 7b,
    # /app/workbench/briefs/persona2/munro.md; genre-fixes, 2026-10-18),
    # replacing the general-knowledge stub of genre-1 (its roller and stab
    # patches and the club master stay: the maintainer's Bench picks).
    Genre.define :techno, 'Techno (Detroit / peak time)' do
      about 'Peak-time techno for DJs: a straight TR-909 four on the floor with a rumble bus (the kick through a dark room, ' \
            'ducked by the kick), 16th hats, a rolling offbeat sub, one detuned stab opening over long phrases with a ' \
            'dotted-eighth echo, an acid line and Detroit strings in the second peak, slow change, 32-bar DJ intro and outro.  ' \
            'From Charlie "Munro" Munro\'s template data for the persona panel of 2026-10-18.'
      tempo 132, range: 128..138
      meter 4, 4
      phrases 16, 32
      key :minor, :f

      # Munro: intro 32 (kick, hats at 16), build 16, peak 32 (one change
      # at 16), breakdown 16 (kick out, a snare build in the last 8),
      # peak2 32, outro 32 (bass out at 1, hats thin at 16, kick alone at
      # 24); a tom roll every 32
      flow do
        fill :toms, every: 32
        intro     16
        hats      16
        build     16, fill: [:noise, 8]
        peak      16
        peak_b    16
        breakdown 16, fill: [:snare_build, 8]
        peak2     32
        outro     16
        outro_b   8
        outro_c   8
      end

      four = 'X...X...X...X...'
      hats = '3535353535353535'
      clap = '....X.......X...'
      rim = '...3..3....3..3.'
      toms = { high_tom: grid(16, '........5.5.....'), mid_tom: grid(16, '............6.6.'), low_tom: grid(16, '..............7X') }
      kit :intro, grid(16, kick: four).loop(align: :launch)
      kit :hats, grid(16, kick: four, closed_hat: hats).loop(align: :launch)
      kit :build, grid(16, kick: four, clap: clap, closed_hat: hats, rimshot: rim).loop(align: :launch)
      # (open hats on the offbeats in the peaks only)
      kit :peak, grid(16, kick: four, clap: clap, closed_hat: hats, open_hat: '..5...5...5...5.', rimshot: rim).loop(align: :launch)
        .fill(:toms, **toms)
      # (the one change at 16: the clap answered on the last 16th)
      kit :peak_b, grid(16, kick: four, clap: '....X.......X..3', closed_hat: hats, open_hat: '..5...5...5...5.', rimshot: rim).loop(align: :launch)
        .fill(:toms, **toms)
      # (the ride arrives in peak2)
      kit :peak2, grid(16, kick: four, clap: clap, closed_hat: hats, open_hat: '..5...5...5...5.', rimshot: rim, ride: '6.4.6.4.6.4.6.4.').loop(align: :launch)
        .fill(:toms, **toms)
      kit :breakdown, grid(16, closed_hat: '..3...3...3...3.').loop(align: :launch)
      # The breakdown's last 8 bars: a snare build, quarters to 16ths,
      # louder each pair of bars, over the thin hats
      kit :snare_build, grid(16,
        closed_hat: '..3...3...3...3.' * 8,
        snare: ('3...3...3...3...' * 2) + ('4.4.4.4.4.4.4.4.' * 2) + ('5555555555555555' * 2) + '6666777788889999' + '99999999XXXXXXXX',
      ).loop(align: :launch)
      kit :outro, grid(16, kick: four, closed_hat: hats, clap: clap).loop(align: :launch)
      kit :outro_b, grid(16, kick: four, closed_hat: '..3...3...3...3.').loop(align: :launch)

      clip :bass, seq(R, F1, F1, R, R, F1, F1, R, R, F1, F1, R, R, F1, Ab1, R).n16.legato(0.5).loop(align: :launch)
      clip :stab, seq(R, R, F3, R, R, R, R, R).n8.bake(chord(0, 3, 7)).loop(align: :launch)
      # A 303 line for peak2 (accents !, slides ~)
      clip :acid, seq(F2, F2, !F3, F2, R, Ab2, ~C3, F2, !Eb3, F2, R, F2, ~G2, Ab2, !F3, R).n16.loop(align: :launch)
      # Detroit strings: Fm9, then Dbmaj7, 16 bars each (once a phrase)
      clip :strings, (0...5).map { |i| seq([F2, C3, Eb3, G3, Ab3][i], *[T] * 15, [Db2, Ab2, C3, F3, Ab3][i], *[T] * 15).n1 }.reduce(:&).legato(0.99).loop(align: :launch)
      clip :bar, seq(R).n1.loop

      knob :cut, 400, range: 150..6000, curve: :exp, unit: 'Hz' # the stab's lowpass
      knob :space, 0.3, range: 0..1                             # the stab's echo send

      role :drums, :tr909, level: -4.db, send: { rumble: -3.db }, about: 'the TR-909, straight; its kick also feeds the rumble bus'
      # (the roller: a short sub with a noise tick in a small room, ducked
      # under the kick, so it rolls between the kicks instead of booming
      # under them; patches-4, 2026-10-13; level +2 dB and duck -4 dB from
      # the maintainer's Bench pick, drums-3)
      role :bass, :roller, level: 2.db, duck: -4.db, about: 'a rolling offbeat sub with a noise tick, ducked under the kick'
      # (Genre::Patches.stab: the Reese's voice with a gentle drive;
      # drums-3.  The heavy one: `role :stab, :stab, params: { cutoff: :cut,
      # drive: 1 }`)
      role :stab, :stab, params: { cutoff: :cut }, level: -9.db, send: { echo: :space }, about: 'a detuned stab opening over the phrase, a dotted-eighth echo'
      role :acid, :acid, level: -12.db, duck: -4.db, about: 'a 303 line for the second peak'
      role :strings, :sq80_flutter_pad, level: -14.db, about: 'a Detroit string chord, once a phrase'
      role :noise, :riser, params: { bars: 8, from: 300, to: 6000, level: 0.15 }, fade: 1/8r, about: 'a filtered noise swell into the peak'

      sidechain :drums, only: :kick
      # The rumble bus (Munro: "the kick's reverb/sub tail ducked by the
      # kick itself"): only the lows of the drums, through a dark room,
      # ducked by the kick so the tail fills the gaps between kicks
      bus :rumble, [:filter, :lowpass, { cutoff: 160, quality: 0.7 }], [:reverb, :hall, { mix: 1 }],
          [:filter, :lowpass, { cutoff: 120, quality: 0.7 }], [:at, 6.db], [:duck, :drums, { only: :kick, amount: -18.db, release: 1.n8 }]
      bus :echo, [:filter, :highpass, { cutoff: 300, quality: 0.7 }], [:delay, 1.n8.dotted, { feedback: 0.4 }]

      scene :intro, drums: :intro, cut: 400
      scene :hats, drums: :hats
      scene :build, drums: :build, bass: :bass, stab: :stab, cut: [1500, { from: 400, over: 16 }]
      scene :noise, noise: :bar, others: :keep
      scene :peak, drums: :peak, bass: :bass, stab: :stab, cut: 2000
      scene :peak_b, drums: :peak_b, bass: :bass, stab: :stab, cut: [3000, { over: 16 }]
      scene :breakdown, drums: :breakdown, stab: :stab, cut: [800, { over: 4 }]
      scene :snare_build, drums: :snare_build, others: :keep
      scene :peak2, drums: :peak2, bass: :bass, stab: :stab, acid: :acid, strings: :strings, cut: [5000, { from: 1500, over: 16 }]
      scene :outro, drums: :outro
      scene :outro_b, drums: :outro_b
      scene :outro_c, drums: :intro

      loudness(-9..-7)
      true_peak(-0.5.db)
      mono_below 120 # club systems
      measure :loudest, bars: 16 # the club master targets the loudest phrase (the kick-only DJ intro and outro stay out of it)
      # (the club mastering preset with its two limiters, no clipper:
      # mastering-2, 2026-10-17, maintainer on the Bench: "The IMD on some
      # of the stabs is noticeable in the clipping variant")
      master :club
      master_gain 0.db

      tip 'Long phrases and slow change: one element enters or opens every 16-32 bars; a filter on a stab (turn :cut) is a whole section\'s movement.'
      tip 'DJ structure: a 32-bar intro (kick, then hats at 16) and a 32-bar outro that takes the bass out first, thins the hats, and leaves the kick alone at the end.'
      tip 'The kick and the bass share the low end: keep the bass off the kick (offbeats), mono, and ducked by the kick voice itself (duck(:drums, only: :kick)).'
      tip 'A rumble bus: send the drums to a dark reverb ducked by the kick, so the tail fills the space between kicks without smearing them; tune the kick to the key.'
      tip 'Render tools alongside the track: a drums-only version (mute everything but :drums) and a one-bar loop of the peak for the DJ\'s own sets.'
    end
  end
end
