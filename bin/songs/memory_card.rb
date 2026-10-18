#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Memory Card (Sunrise Mix)" by Skylark Junction: optimistic atmospheric jungle at 165 BPM.
#
# Skylark Junction is the act of Nev Ashdown, a fictional 90s jungle
# producer written for the persona panel experiment (2026-10-13: four
# musician personas reviewed the API and each wrote a 2-3 minute demo with
# it; research branch research-persona-jungle, research/persona-panel/jungle/,
# with Nev's review, friction log, and a performed take).  The song moved
# here from that branch; its patches, the sampler included, live in
# bin/synths/jungle.rb (playable from MIDI, and saved as presets).
#
# In D minor / F major, 96 bars (about 2:20 plus the ring-out).  Written
# with the public mb-sound API only.
#
# The break is the point.  The song first presses its own "record"
# (bounced into a Sample; when Nev wrote it there was no sampler yet, and
# the slices were sample-mode Wavetables in a KeyMap): a two-bar funk break played on
# the TR-808 kit (tuned up to sound more like a kit than a drum machine)
# at 138.75 BPM in a small room, softclipped like tape (.jungle_record).
# Then it does what we did on the S950: cuts the record into slices,
# truncates them to 12 bits, puts each slice on its own key
# (.memory_card_break, a Sample::Slices, and its keymap; a keyboard plays
# them through jungle.rb's .jungle_sampler zones) and plays the slices
# from chop patterns whose hits carry pitch marks three semitones up, so
# 138.75 BPM lands on 165 (2^(3/12) * 138.75 = 165.0: pitch it up until it fits).  The
# whole record is a slice too (:full), so rolling sections loop it in
# time.  One voice: every new slice truncates the last, like a mono
# sampler.  Ghost notes, pitched snare rolls, and a reversed snare are
# slices played from patterns (.memory_card_chops).
#
#   intro     8  string pad (Dm9 Bbmaj9 Fmaj9 C11, two bars each), ride
#   lift      8  + the whole break, lowpassed, opening up (:brk knob)
#   roll     16  the break rolling open, sine sub, Rhodes stabs, shaker
#   drop     16  chopped break (chop A), sub line, Rhodes, pad
#   breakdown 16 drums out but the ride; pad, Rhodes, flute lead with a
#                dotted-eighth echo; the last 4 bars a snare roll pitching
#                up into the drop (fill) and a noise riser
#   drop2    16  busier chops (chop B), a warm Reese over the sub, the lead
#   outro    16  the break rolling again, pad, sub; then break and ride
#                alone for the DJ (outro2), and everything rings out
#
# Usage:
#     bin/songs/memory_card.rb                # plays live
#     bin/songs/memory_card.rb out.flac       # renders
#     bin/songs/memory_card.rb --stems dir/ out.flac
#     bin/songs/memory_card.rb --vinyl out.flac      # the vinyl preset, drums rebalanced for it
#     bin/songs/memory_card.rb --help
#
# Or in bin/sound.rb:
#     load 'bin/songs/memory_card.rb'
#     memory_card                 # tracks and scenes (go :drop etc.), then
#     memory_card_form            # the form
#
# Try (while it plays):
#     go :drop2                                # straight to the Reese
#     turn :brk, 600, over: 2                  # the break into its filter
#     turn :brk, 16000, over: 1.beat           # and open again
#     swap :breaks, memory_card_chops[:b]      # chop B under anything
#     turn :space, 0.8; turn :space, 0.3, on: :bar   # throw the lead's echo

# As rendered by Nev on the research branch (2026-10-13, measured; nobody
# had listened yet): -11.5 LUFS integrated, -0.8 dBTP (limiter at -1 dBTP);
# sections from -16.1 (intro) to -9.1 LUFS (drop2).
#
# Mastered with Nev's own glue and limiter (-D/-C).  --vinyl masters with
# the vinyl preset instead (omnibus9, 2026-10-18, its default until
# bench-fixes-1: the maintainer on the omnibus9 Bench, "The vinyl master
# is good for hi-fi but shouldn't be the default"; on mastering-2: "the
# original master was relying on the master chain to bring the drums in
# line ... the drums, especially snare, become dominant"), so with it the
# drums play at MEMORY_CARD_DRUMS (snare
# slices -5 dB in all, the rest of the break -2 dB, perc -1.5 dB), so the
# drums sit under the music as Nev's glue and limiter had them.  Drums
# alone against the music alone (LUFS of the drop / drop2): Nev's master
# -4.8 / -6.0 LU; vinyl at the old levels -2.3 / -4.1; vinyl rebalanced
# -5.0 / -6.4.  The vinyl render: -16.7 LUFS integrated (-17.5 at the old
# levels), -1.0 dBTP (the ceiling holds it: no brickwall).
#
require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/jungle'

module MB::Sound
  MEMORY_CARD_BPM = 165
  MEMORY_CARD_BARS = 98

  # The record's tempo: three semitones below the song, so the slices
  # played three semitones up land exactly on the song's grid.
  MEMORY_CARD_RECORD_BPM = MEMORY_CARD_BPM / 2 ** (3 / 12.0)

  # The record's slices (Sample::Slices; .jungle_slices_of at the
  # record's tempo), pressed once.
  def self.memory_card_break
    @memory_card_break ||= jungle_slices_of(bpm: MEMORY_CARD_RECORD_BPM)
  end

  # A chop pattern in 16ths (Sample::Slices#chop on .memory_card_break):
  # slice names (see .jungle_slices; :rev is the snare run backwards),
  # [name, semitones] for pitched slices, and Tie/Rest (T/R) steps, three
  # semitones up so the record lands on the song's grid; e.g.
  # chop(:k, T, :h, :g, [:s, 2]).  Every hit carries a pitch mark, so
  # `chop(...).transpose(2)` pitches the hits, not the slices.
  #
  # +snare+ (a gain) plays the snare slices (MEMORY_CARD_SNARES) that much quieter or louder, through their
  # velocities (the breaks voice's gain follows velocity / 0.75).
  def self.chop(*steps, snare: 1.0)
    brk = memory_card_break
    rev = brk[:s2].rev
    vel = 0.75 * snare.to_f
    brk.chop(*steps.map { |s|
      name, semis = s.is_a?(Array) ? s : [s, 0]
      next(s == :rev ? rev : s) if snare == 1 || !MEMORY_CARD_SNARES.include?(name)
      [name, semis, { vel: vel }]
    }).transpose(3)
  end

  # The slices with a snare hit (see .jungle_slices; the reversed run, a
  # swell, keeps its level: chop steps take velocities only by name).
  MEMORY_CARD_SNARES = %i[s sk s2 s3].freeze

  # The drum levels the vinyl master needs (omnibus9, 2026-10-18): the
  # old master's glue and limiter squashed the drums (the snare most) into
  # the mix; without them the snare was dominant (the maintainer's
  # mastering-2 Bench note).  Snare slices -3 dB more than the rest of the
  # break, the break -2 dB, the perc kit -1.5 dB.
  MEMORY_CARD_DRUMS = { snare: -3.db, breaks: -2.db, perc: -1.5.db }.freeze

  # The chop patterns (looping clips, named).
  def self.memory_card_chops(snare: 1.0)
    roll_up = (0...16).map { |i| [:s, (i * 6 / 15.0).round] }
    chop = ->(*steps) { self.chop(*steps, snare: snare) }
    s = snare.to_f
    {
      full: chop.(:full, *[T] * 31),
      a: chop.(
        :k, T, :h, :g,   :sk, T, T, T,   :h, T, :kk, T,   :s2, T, T, T,
        :k2, T, T, T,    :s3, T, T, T,   :h, :g, :kk, T,  :s, T, [:g, 2], [:s, 3],
      ),
      b: chop.(
        :k, T, :g, :k,   :s, T, :g, :h,  T, :k, :kk, T,   :s2, T, :g, :h,
        :k2, T, T, T,    :s, :g, :s3, T, T, T, :kk, T,    :rev, T, T, T,
        :k, T, :h, :g,   :sk, T, T, T,   :k, :g, :kk, T,  :s2, T, T, :g,
        :k2, T, T, T,    :s3, T, T, T,   :h, :g, :kk, :g, [:s, 1], [:s, 2], [:s, 4], [:s, 6],
      ),
      # The build: snares in quarters, eighths, sixteenths, then a rising
      # sixteenth roll (4 bars), getting louder
      build: chop.(*[:s, T, T, T] * 4).vel(0.3 * s) | chop.(*[:s, T] * 8).vel(0.4 * s) | chop.(*[:s] * 16).vel(0.5 * s) | chop.(*roll_up).vel(0.7 * s),
      none: chop.(R),
    }.transform_values { |c| c.loop(align: :launch) }.each { |name, c| c.named(:"chop_#{name}") }
  end

  # Perc kits: the ride on eighths (accents on the beat), a shaker, a crash
  # on the first bar of every 16.
  def self.memory_card_kits
    ride = '6.4.6.4.6.4.6.4.'
    shaker = '3537353735373537'
    kit = ->(crash: false, **rows) {
      all = { ride: '', maracas: '', crash: '' }.merge(rows)
      all[:crash] = 'X' + '.' * 15 if crash
      k = grid(16, **all.transform_values { |p| p.empty? ? '.' * 16 : p })
      Sequence::Kit.new(k.rows.to_h { |name, c| [name, name == :crash ? c.every(16) : c] })
    }
    {
      ride: kit.(ride: ride),
      full: kit.(ride: ride, maracas: shaker),
      drop: kit.(ride: ride, maracas: shaker, crash: true),
    }.transform_values { |k| k.loop(align: :launch) }.each { |name, k| k.named(:"perc_#{name}") }
  end

  # Chords as a Clip: each chord an Array of Notes, all +length+ long.
  def self.memory_card_chords(chords, length)
    size = chords.map(&:length).max
    (0...size).map { |i| seq(*chords.map { |c| c[i] || R }).public_send(length) }.reduce(:&)
  end

  # The progression, two bars per chord: Dm9, Bbmaj9, Fmaj9, C11
  # (vi-IV-I-V in F: sunrise music).
  MEMORY_CARD_VOICINGS = [
    [C3, E3, F3, A3],
    [C3, D3, F3, A3],
    [C3, E3, G3, A3],
    [Bb2, D3, F3, G3],
  ].freeze

  # The clips of the song.
  def self.memory_card_clips
    v = MEMORY_CARD_VOICINGS
    stab = ->(chord) {
      # Rhodes stabs over two bars: the "and" of 2, beat 4 (held), and a
      # push into the next bar
      memory_card_chords([chord], :n8).then { |hit|
        rest = seq(R).n8
        (rest * 3) | hit | (rest * 2) | memory_card_chords([chord], :n4) | (rest * 3) | hit.legato(0.9) | (rest * 4)
      }
    }
    keys = v.map { |c| stab.(c) }.reduce(:|)
    pad = memory_card_chords(v.flat_map { |c| [c.map { |n| n.transpose(12) }] * 2 }, :n1).legato(0.98)
    {
      pad: pad,
      keys: keys,
      sub: seq(
        D2.n2.d, D2.n8, C2.n8, D2.n1,
        Bb1.n2.d, Bb1.n8, C2.n8, Bb1.n2, F1.n2,
        A1.n2.d, A1.n8, C2.n8, A1.n2, G1.n4, A1.n4,
        C2.n2.d, C2.n8, D2.n8, C2.n2, E2.n4, G1.n4,
      ),
      roots: seq(D2, D2, Bb1, Bb1, A1, A1, C2, C2).n1,
      lead: seq(
        A4.n4.d, G4.n8, F4.n4, D4.n4,   E4.n2.d, R.n4,
        F4.n4.d, E4.n8, D4.n4, C4.n4,   D4.n1,
        A4.n4.d, C5.n8, A4.n4, G4.n4,   F4.n2, E4.n4, D4.n4,
        E4.n4.d, F4.n8, G4.n4, A4.n4,   A4.n1,
      ),
      bar: seq(R).n1,
    }.transform_values { |c| c.loop(align: :launch) }.each { |name, c| c.named(name) }
  end

  # A noise riser: a bandpass sweeping up over 4 bars, swelling.
  def self.memory_card_riser
    sweep = tween([400, 8000], 4.bars, log: true, loop: false)
    noise.filter(:bandpass, cutoff: sweep, quality: 2.0) * tween([0.02, 0.12], 4.bars, loop: false)
  end

  # Sets up the song on the current session: tempo, knobs, master, tracks,
  # scenes.  Returns the chops and clips.
  #
  # By default Nev's original: the song's glue and limiter (+drive+,
  # +ceiling+) with the drums as loud as he had them.  +vinyl+ (true)
  # masters with the vinyl preset and plays the drums at
  # MEMORY_CARD_DRUMS (+drums+ overrides): hi-fi, not the default
  # (maintainer, omnibus9 Bench).
  def self.memory_card(drive: 5.0, ceiling: -1.0, vinyl: false, drums: nil)
    drums ||= vinyl ? MEMORY_CARD_DRUMS : { snare: 1, breaks: 1, perc: 1 }
    map = memory_card_break.instrument # (the record bounces at its own tempo)
    chops = memory_card_chops(snare: drums[:snare])
    c = memory_card_clips
    k = memory_card_kits
    bpm MEMORY_CARD_BPM
    quant 1

    knob :brk, 16000, range: 200..16000, curve: :exp, unit: 'Hz' # the break's lowpass
    knob :space, 0.3, range: 0..1                              # the lead's echo send

    master_gain 1
    if vinyl
      master :vinyl
    else
      master { |mix|
        glued = mix.compress(threshold: -14.db, ratio: 2, knee: 8, attack: 0.02, release: 0.15)
        (glued * drive.db).limit(ceiling: ceiling.db, release: 0.1)
      }
    end

    breaks_gain = drums[:breaks].to_f
    perc_gain = drums[:perc].to_f
    track(:breaks) { |clip| jungle_breaks_voice(clip, map: map, cutoff: knob(:brk), level: 1.6 * breaks_gain) }
    track(:perc) { |kit| perc_gain == 1 ? jungle_perc(kit) : jungle_perc(kit) * perc_gain }
    track(:sub) { |clip| jungle_sub_voice(clip) }
    track(:reese) { |clip| jungle_reese_voice(clip) }
    track(:keys) { |clip| jungle_keys_voice(clip) }
    track(:pad) { |clip| jungle_pad_voice(clip) }
    track(:lead) { |clip| jungle_flute_voice(clip, send: knob(:space)) }
    track(:riser, fade: 1/8r) { |_clip| memory_card_riser }

    # The breaks stay loaded on a silent chop from the start (scenes swap
    # its clips instead of rebuilding it).
    scene :intro, pad: c[:pad], perc: k[:ride], breaks: chops[:none], brk: 16000
    scene :lift, pad: c[:pad], perc: k[:ride], breaks: chops[:full], brk: [3500, from: 350, over: 8, curve: :smooth]
    scene :roll, pad: c[:pad], perc: k[:drop], breaks: chops[:full], sub: c[:roots], keys: c[:keys], brk: 16000
    scene :drop, pad: c[:pad], perc: k[:drop], breaks: chops[:a], sub: c[:sub], keys: c[:keys]
    scene :breakdown, pad: c[:pad], perc: k[:ride], breaks: chops[:none], keys: c[:keys], lead: c[:lead]
    scene :build, breaks: chops[:build], riser: c[:bar], others: :keep
    scene :drop2, pad: c[:pad], perc: k[:drop], breaks: chops[:b], sub: c[:sub], reese: c[:sub], keys: c[:keys], lead: c[:lead], brk: 16000
    scene :outro, pad: c[:pad], perc: k[:full], breaks: chops[:full], sub: c[:roots], keys: c[:keys]
    scene :outro2, perc: k[:ride], breaks: chops[:full], brk: [2500, over: 8, curve: :smooth]

    { chops: chops, clips: c, kits: k }
  end

  # The song form (each section launches the scene of its name).
  def self.memory_card_form(play: true)
    flow(play: play) do
      intro      8
      lift       8
      roll      16
      drop      16
      breakdown 16, fill: [:build, 4]
      drop2     16
      outro      8
      outro2     8
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: MEMORY_CARD_BARS,
      drive: [5.0, Float, '-D', 'Gain in dB into the master limiter (Nev\'s master)', -20.0..20.0],
      ceiling: [-1.0, Float, '-C', 'Master limiter true-peak ceiling in dBTP (Nev\'s master)', -12.0..0.0],
      vinyl: [false, 'The vinyl preset (mono lows, de-esser, no brickwall) with the drums rebalanced for it, instead of Nev\'s glue and limiter'],
    ) { |p|
      memory_card(drive: p.drive, ceiling: p.ceiling, vinyl: p.vinyl)
      memory_card_form
    }
  end
end
