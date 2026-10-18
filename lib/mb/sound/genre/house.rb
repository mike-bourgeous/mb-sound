module MB
  module Sound
    # Deep house for DJs (Detroit/Chicago-leaning), from Charlie "Munro"
    # Munro's template data (persona panel round 2 sheet, section 7b,
    # /app/workbench/briefs/persona2/munro.md; genre-fixes, 2026-10-18),
    # replacing the general-knowledge stub of genre-1.  Drums on the
    # tr909 (drums-2/3), the master the club preset (mastering-2, the
    # maintainer's Bench pick).
    Genre.define :house, 'House (Detroit/Chicago deep house)' do
      about 'Deep house for DJs: four on the floor on a TR-909 with shuffle 2, claps on 2 and 4, open hats on the "and"s, ' \
            'a one-saw bass bouncing in octaves (swung with the hats, ducked by the kick), Rhodes stabs under a knob, ' \
            'strings that change once a phrase, a ride and shaker pickup, 16-bar DJ intro and outro.  ' \
            'From Charlie "Munro" Munro\'s template data for the persona panel of 2026-10-18.'
      tempo 124, range: 120..128
      meter 4, 4
      phrases 8, 16, 32
      key :minor, :a

      # Munro: intro 16 (drums), groove 16, breakdown 16, drop 32 with a
      # pickup at 17 (ride and shaker), breakdown2 8, drop2 32, outro 16
      # (bass out at 1, the rest out at 9: drums alone)
      flow do
        fill :clap_roll, every: 16
        intro      16
        groove     16
        breakdown  16, fill: [:riser, 4]
        drop       16
        pickup     16
        breakdown2 8
        drop2      32
        outro      8
        outro2     8
      end

      four = 'X...X...X...X...'
      offbeat = '..6...6...6...6.'
      clap = '....X.......X...'
      # (the roll at the end of every 16: 16ths rising into a flam, Munro's
      # "a drum fill, not a kettle")
      roll = { clap: grid(16, '....3.4.5.6.7.8F') }
      # Closed hats in 16ths, soft under the kick and accented on the
      # offbeats (the open hat takes the "and"s where it plays)
      kit :intro, grid(16, kick: four, closed_hat: '2.5.2.5.2.5.2.5.').loop(align: :launch)
        .fill(:clap_roll, **roll)
      # (ghost 16ths on the closed hat so the 909's shuffle 2 swings them)
      kit :groove, grid(16, kick: four, clap: clap, open_hat: offbeat, closed_hat: '5.3.5.335.3.5.32').loop(align: :launch)
        .nofill(:clap, name: :clap_roll).fill(:clap_roll, **roll)
      # (the drop: closed hats on every 16th but the open hats' offbeats,
      # so the 909's shuffle swings every second one; drums-3)
      kit :drop, grid(16, kick: four, clap: clap, open_hat: offbeat, closed_hat: '65.565.565.565.5').loop(align: :launch)
        .nofill(:clap, name: :clap_roll).fill(:clap_roll, **roll)
      kit :breakdown, grid(16, closed_hat: '..3...3...3...3.').loop(align: :launch)
      kit :breakdown2, grid(16, kick: four, clap: clap, closed_hat: '2.5.2.5.2.5.2.5.').loop(align: :launch)
        .nofill(:clap, name: :clap_roll).fill(:clap_roll, **roll)
      # (the pickup at bar 17 of the drop: the ride on the offbeats, with
      # the perc role's shaker)
      kit :pickup, grid(16, kick: four, clap: clap, open_hat: offbeat, closed_hat: '65.565.565.565.5', ride: '..5...5...5...5.').loop(align: :launch)
        .nofill(:clap, name: :clap_roll).fill(:clap_roll, **roll)
      kit :shaker, grid(16, maracas: '4847484748474847').loop(align: :launch)

      # The bass bounces between octaves on the offbeat 16ths, swung like
      # the 909's shuffle 2 (28/48 of an eighth: everything with 16ths
      # shares the swing)
      clip :bass, seq(R, A1, A2, R, R, A1, A2, R, R, A1, A2, R, R, G1, G2, R).n16.legato(0.6).swing(7/12r).loop(align: :launch)
      # drop2: a new bass note pattern (Munro: a variation, not a copy)
      clip :bass2, seq(R, A1, A2, R, R, A1, C3, R, R, A1, A2, R, E2, G1, G2, R).n16.legato(0.6).swing(7/12r).loop(align: :launch)
      clip :chords, (0...3).map { |i| seq(*[[A3, C4, E4], [G3, B3, D4]].flat_map { |c| [R, c[i], R, R, R, c[i], R, R] }).n8 }.reduce(:&).loop(align: :launch)
      # Strings that change once a phrase: Am9, then Fmaj9, 16 bars each
      clip :strings, (0...5).map { |i| seq([A2, E3, G3, B3, C4][i], *[T] * 15, [F2, C3, E3, G3, A3][i], *[T] * 15).n1 }.reduce(:&).legato(0.99).loop(align: :launch)
      clip :bar, seq(R).n1.loop

      knob :cut, 8000, range: 200..12000, curve: :exp, unit: 'Hz' # the stabs' lowpass

      role :drums, :tr909, level: -4.db, params: { shuffle: 2 }, about: 'the TR-909 with shuffle 2, the house kit'
      role :bass, :house_bass, level: 3.db, duck: -3.db, about: 'one saw, a tempo-set decay, bouncing in octaves, ducked 3 dB by the kick'
      role :keys, :tine_piano, filter: :cut, level: -4.db, about: 'Rhodes-ish stabs on the offbeats, under the :cut knob'
      role :pad, :jungle_pad, level: 0.db, duck: -2.db, about: 'string pad, one chord a phrase, breathing with the kick'
      role :perc, :tr808, level: -2.db, about: 'an 808 shaker in 16ths for the pickup (soft, accent, soft)'
      role :riser, :riser, params: { bars: 4 }, fade: 1/8r, about: 'noise riser into the drop'

      # Ducks key from the drums track's own kick voice (Munro: "the pads
      # can breathe, the sub can't")
      sidechain :drums, only: :kick

      scene :intro, drums: :intro
      scene :groove, drums: :groove, bass: :bass, keys: :chords, cut: [8000, { from: 800, over: 16 }]
      scene :breakdown, drums: :breakdown, keys: :chords, pad: :strings, cut: 1500
      scene :drop, drums: :drop, bass: :bass, keys: :chords, pad: :strings, cut: 8000
      scene :pickup, drums: :pickup, bass: :bass, keys: :chords, pad: :strings, perc: :shaker
      scene :breakdown2, drums: :breakdown2, keys: :chords, pad: :strings, cut: 2500
      scene :drop2, drums: :pickup, bass: :bass2, keys: :chords, pad: :strings, perc: :shaker, cut: 8000
      scene :outro, drums: :intro, keys: :chords, pad: :strings
      scene :outro2, drums: :intro
      scene :riser, riser: :bar, others: :keep

      loudness(-10..-8)
      true_peak(-0.5.db)
      mono_below 120 # club systems
      # (the club mastering preset with its gentle clipper, the house feel:
      # mastering-2, 2026-10-17, maintainer on the Bench: "The two limiter
      # setup isn't much different so both are good to have"; Munro's
      # compress 2:1, light softclip, limit is the same shape)
      master :club, clip: true
      master_gain 0.db

      tip 'DJ structure: 16-32 bar intros and outros of drums for mixing, changes on 8- and 16-bar lines, the bass out first in the outro and the drums alone at the end.'
      tip 'Four on the floor, claps on 2 and 4, open hats on the offbeats, closed hats in 16ths soft under the kick; the groove lives in the hats and the bass.'
      tip 'Swing the bass with the hats: the 909\'s shuffle 2 is a 28/48 swing, so the bass clip gets .swing(7/12r) ("straight bass wants straight drums").'
      tip 'Sidechain lightly from the kick voice itself (duck(:drums, only: :kick)): the bass 2-6 dB, the pads 1-3 dB, released before the next kick.'
      tip 'A clap a few ms late relaxes the groove, hats a few ms early push it; leave one rough edge in (a loop left unquantized, a hat played in).'
    end
  end
end
