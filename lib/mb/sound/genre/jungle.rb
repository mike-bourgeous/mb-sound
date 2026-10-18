module MB
  module Sound
    # 1990s-2000s optimistic (atmospheric) jungle, from the persona panel
    # (2026-10-13): Nev Ashdown's research (research-persona-jungle,
    # research/persona-panel/jungle/research.md) and "Memory Card"
    # (bin/songs/memory_card.rb, patches in bin/synths/jungle.rb and
    # presets/jungle_*.mbg.rb; the break is `breakbeat(:jungle)`, the
    # jungle_breaks bundle's record, chopped with Slices#chop).
    Genre.define :jungle, 'Jungle (90s atmospheric)' do
      about 'Chopped breaks over half-time pads: a sliced break re-sequenced in 16ths, ' \
            'a sine sub, Rhodes stabs and string pads in jazz chords, a flute lead, long DJ builds.  ' \
            'From Nev Ashdown ("Memory Card") in the persona panel of 2026-10-13.'
      tempo 165, range: 155..175
      meter 4, 4
      phrases 8, 16, 32
      key :minor, :d

      flow do
        intro     16
        lift      16
        roll      16
        drop      32
        breakdown 16, fill: [:build, 4]
        drop2     32
        outro     16
      end

      # The chop is the instrument (genre-fixes, 2026-10-18; Nev: "You
      # built the sampler and the template didn't move in"): the shipped
      # break (Nev's record, two bars pressed at 138.75 BPM, 12-bit) cut
      # into its 32 sixteenths, with names for its runs: kick, hat, snare,
      # snare + ghost kick, ghost snare, kick on the "and" of 3, snare +
      # open hat, double kick, snare 3, the whole record.  Chops play the
      # slices with pitch marks (3 semitones up: 138.75 lands on 165), so
      # slice and pitch stay apart; brk[:s2].rev is the snare backwards.
      brk = breakbeat(:jungle).slices(32).name(k: 0..1, h: 2..3, s: 4..5, sk: 4..7, g: 7..7, kk: 10..11, s2: 12..15, k2: 16..19, s3: 20..23, full: 0..31)
      clip :full, brk.chop(:full, *[T] * 31).transpose(3).loop(align: :launch)
      clip :chop_a, brk.chop(
        :k, T, :h, :g,   :sk, T, T, T,   :h, T, :kk, T,   :s2, T, T, T,
        :k2, T, T, T,    :s3, T, T, T,   :h, :g, :kk, T,  :s, T, [:g, 2], [:s, 3],
      ).transpose(3).loop(align: :launch)
      clip :chop_b, brk.chop(
        :k, T, :g, :k,   :s, T, :g, :h,     T, :k, :kk, T,   :s2, T, :g, :h,
        :k2, T, T, T,    :s, :g, :s3, T,    T, T, :kk, T,    brk[:s2].rev, T, T, T,
      ).transpose(3).loop(align: :launch)
      clip :build, brk.chop(*[:s, T] * 8, *(0...16).map { |i| [:s, (i * 6 / 15.0).round] }).transpose(3).loop(align: :launch)
      clip :no_break, brk.chop(nil, per: 1).loop

      ride = '6.4.6.4.6.4.6.4.'
      shaker = '3537353735373537'
      kit :ride, grid(16, ride: ride).loop(align: :launch)
      kit :perc, grid(16, ride: ride, maracas: shaker).loop(align: :launch)

      voicings = [[C3, E3, F3, A3], [C3, D3, F3, A3], [C3, E3, G3, A3], [Bb2, D3, F3, G3]] # Dm9 Bbmaj9 Fmaj9 C11
      clip :pad, (0...4).map { |i| seq(*voicings.flat_map { |c| [c[i].transpose(12)] * 2 }).n1 }.reduce(:&).legato(0.98).loop(align: :launch)
      clip :keys, (0...4).map { |i| seq(*voicings.flat_map { |c| [R, R, R, c[i], R, R, c[i], R, R, R, R, c[i], R, R, R, R] }).n8 }.reduce(:&).loop(align: :launch)
      clip :sub, seq(
        D2.n2.d, D2.n8, C2.n8, D2.n1,
        Bb1.n2.d, Bb1.n8, C2.n8, Bb1.n2, F1.n2,
        A1.n2.d, A1.n8, C2.n8, A1.n2, G1.n4, A1.n4,
        C2.n2.d, C2.n8, D2.n8, C2.n2, E2.n4, G1.n4,
      ).loop(align: :launch)
      clip :lead, seq(
        A4.n4.d, G4.n8, F4.n4, D4.n4, E4.n2.d, R.n4,
        F4.n4.d, E4.n8, D4.n4, C4.n4, D4.n1,
      ).loop(align: :launch)
      clip :bar, seq(R).n1.loop

      knob :brk, 16000, range: 200..16000, curve: :exp, unit: 'Hz'   # the break's lowpass
      knob :space, 0.3, range: 0..1                                  # the lead's echo send

      role :breaks, :breaks, params: { cutoff: :brk }, about: 'the chopped break: slices of the shipped break on one voice, each hit cutting the last, 12-bit'
      role :perc, :jungle_perc, about: 'ride and shaker over the break'
      role :sub, :jungle_sub, about: 'sine sub, long notes under busy breaks'
      role :reese, :jungle_reese, level: -3.db, about: 'a warm Reese for the second drop, used sparingly'
      role :keys, :jungle_keys, about: 'Rhodes-ish stabs in jazz chords'
      role :pad, :jungle_pad, about: 'slow string pad, Juno chorus, hall'
      role :lead, :jungle_flute, params: { echo: :space }, about: 'flute with a dotted-eighth echo'
      role :riser, :riser, params: { bars: 4, from: 400, to: 8000, level: 0.12 }, fade: 1/8r, about: 'noise riser (in the build fill)'

      scene :intro, pad: :pad, perc: :ride, breaks: :no_break, brk: 16000
      scene :lift, pad: :pad, perc: :ride, breaks: :full, brk: [3500, { from: 350, over: 8, curve: :smooth }]
      scene :roll, pad: :pad, perc: :perc, breaks: :full, sub: :sub, keys: :keys, brk: 16000
      scene :drop, pad: :pad, perc: :perc, breaks: :chop_a, sub: :sub, keys: :keys
      scene :breakdown, pad: :pad, perc: :ride, breaks: :no_break, keys: :keys, lead: :lead
      scene :build, breaks: :build, riser: :bar, others: :keep
      scene :drop2, pad: :pad, perc: :perc, breaks: :chop_b, sub: :sub, reese: :sub, keys: :keys, lead: :lead, brk: 16000
      scene :outro, perc: :ride, breaks: :full, sub: :sub, pad: :pad, brk: [2500, { over: 8, curve: :smooth }]

      loudness(-12..-9)
      true_peak(-1.db)
      mono_below 150 # cut for vinyl: mono below 150 Hz
      loudest_bars 16 # the club master's loudest-part window: one phrase
      master :compress, threshold: -14.db, ratio: 2, knee: 8, attack: 0.02, release: 0.15
      master :at, 5.db
      master :limit, ceiling: -1.db, release: 0.1
      master_gain 0.db

      tip 'The chop is the instrument: re-sequence slices of a break in 16ths (kick-snare reorders, ghost snares at low velocity, pitched snare rolls into the drop, a reversed hit): brk = breakbeat(:jungle).slices(32).name(k: 0..1, s: 4..5); brk.chop(:k, T, [:s, 2], brk[:s].rev).'
      tip 'Pitch the record until it fits: a break recorded at 138.75 BPM played 3 semitones up lands exactly on 165.'
      tip 'Half-time underneath: pads and bass move at half the drums\' speed, in jazz and soul chords (minor 9ths, major 7ths, 11ths).'
      tip 'Long builds for DJs: 16-32 bar intros of pads and filtered breaks (turn :brk), breakdowns with only pads, keys and a lead, then the full break and the sub back together.'
      tip 'Master for vinyl, not for the loudness war: mono below 150 Hz, transient-rich breaks, about -11 LUFS with peaks well above the average.'
    end
  end
end
