#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Press and Chop: a 24-bar jungle sketch made only from sounds the song
# presses itself with the sampler (design/notes/sampler.md, 2026-10-13).
#
# Nothing here is a recording: a funk break is played on a tuned-up TR-808
# at 138.75 BPM and bounced into a Sample (the "record"), cut into 32nds,
# run through an S950-ish converter, and chopped; three semitones up the
# record lands on the song's 165 BPM grid.  A detuned saw is bounced into a
# Reese sample and played back as the bass (a ping-pong loop under a held
# note); a formant chord is bounced and cyclically timestretched into a
# metallic pad.
#
#   bars 1-4    the whole record rolling, lowpassed, opening up
#   bars 5-12   chop A with the resampled Reese
#   bars 13-16  breakdown: the stretched pad, a reversed snare roll pitching up
#   bars 17-24  chop B (busier, pitched ghost rolls), Reese, pad tail
#
# Usage:
#     bin/songs/press_and_chop.rb                 # plays live
#     bin/songs/press_and_chop.rb out.flac        # renders
#     bin/songs/press_and_chop.rb --stems dir/ out.flac
#     bin/songs/press_and_chop.rb -l sp1200 out.flac   # grittier converter (or mpc60, none)
#
# Or in bin/sound.rb:
#     load 'bin/songs/press_and_chop.rb'
#     brk = press_and_chop_break                  # the sliced record (Sample::Slices)
#     bg :b, brk.chop(:k, T, :h, :g, :s, T, [:g, 2], :k).loop.transpose(3).sampler(brk).at(-10.db)
#     swap :b, brk.chop(:k, :k, :s, brk[:s].rev).loop.transpose(5)   # same slices, higher
#     play press_and_chop_record.rev.node         # the whole record backwards, once
require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  PRESS_AND_CHOP_BPM = 165
  PRESS_AND_CHOP_BARS = 24

  # The record's tempo: three semitones below the song.
  PRESS_AND_CHOP_RECORD_BPM = PRESS_AND_CHOP_BPM / 2**(3 / 12.0)

  # The record: two bars of a funk break pressed at the record's tempo (a
  # mono Sample with its tempo, so `at(7.n16)` counts its own sixteenths).
  def self.press_and_chop_record
    bounce(2.bars, bpm: PRESS_AND_CHOP_RECORD_BPM) {
      tr808(
        grid(16,
          kick:     'X.....x...X.....|X.x.......X..x..',
          snare:    '....X..3.3..X..3|.3..X..3....X.3.',
          hat:      'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx',
          open_hat: '..............x.|......x.........',
        ),
        kick: { tune: 58, decay: 0.32, tone: 0.65 },
        snare: { tune: 205, decay: 0.16, tone: 0.7, snappy: 0.75 },
        closed_hat: { decay: 0.045, tone: 0.75, level: 0.3 },
        open_hat: { decay: 0.25, tone: 0.7, level: 0.3 },
        accent: 8, velocity_curve: :grid, seed: 165
      ).reverb(:room, mix: 0.18).softclip(0.5, 0.95)
    }
  end

  # The record through a sampler's converter (+lofi+: a Sample::Lofi
  # preset, or :none), cut into its 32 sixteenths with names for the hits
  # (a Sample::Slices).
  def self.press_and_chop_break(record = press_and_chop_record, lofi: :s950)
    record = record.lofi(lofi) unless lofi.nil? || lofi == :none
    record.slices(32).name(
      full: 0..31, k: 0..1, h: 2..3, s: 4..5, sk: 4..7, g: 7, kk: 10..11, s2: 12..15, k2: 16..19, s3: 20..23,
    )
  end

  # The chop patterns (looping clips at the record's pitch; transpose 3 to
  # play them on the song's grid).
  def self.press_and_chop_chops(brk)
    roll = (0...16).map { |i| [:s, (i * 7 / 15.0).round] }
    {
      full: brk.chop(:full, *[T] * 31),
      a: brk.chop(
        :k, T, :h, :g,   :sk, T, T, T,   :h, T, :kk, T,   :s2, T, T, T,
        :k2, T, T, T,    :s3, T, T, T,   :h, :g, :kk, T,  :s, T, [:g, 2], [:s, 3],
      ),
      b: brk.chop(
        :k, T, :g, :k,   :s, T, :g, :h,  T, :k, :kk, T,   :s2, T, :g, :h,
        :k2, T, T, T,    :s, :g, :s3, T, brk[:s].rev, T, :kk, T, brk[:s2].rev, T, T, T,
        :k, T, :h, :g,   :sk, T, T, T,   :k, :g, :kk, T,  :s2, T, T, :g,
        :k2, T, T, T,    :s3, T, T, T,   :h, :g, [:g, 3], [:g, 5], [:s, 1], [:s, 2], [:s, 4], [:s, 6],
      ),
      roll: brk.chop(*[:s, T, T, T] * 4) | brk.chop(*[:s, T] * 8) | brk.chop(*[:s] * 16) | brk.chop(*roll),
    }.transform_values(&:loop)
  end

  # The Reese: five detuned saws through a lowpass, bounced at F1 (a Sample
  # looped back and forth through its middle, so held notes sustain).
  def self.press_and_chop_reese
    F1.unison(5, detune: 22.cents, seed: 7) { |p| p.saw }.lp4(700, resonance: 0.25)
      .bounce(1.n2, bpm: PRESS_AND_CHOP_BPM, root: F1)
      .looped(0.05..0.3, mode: :ping_pong)
  end

  # The pad: a formant-filtered C minor 9 chord, bounced and stretched to
  # twice its length in 30 ms cycles (the S950's cyclic timestretch: a
  # metallic buzz at 33 Hz).
  def self.press_and_chop_pad
    chord = [C3, Eb3, G3, Bb3, D4].map(&:ramp).sum * 0.2
    chord.formant(:a, :o, morph: 0.4.hz.lfo.at(0..1)).bounce(2.bars, bpm: PRESS_AND_CHOP_BPM, root: C3)
      .fade(in: 0.4, out: 1.5).stretch(2, cycle: 30.ms, crossfade: 3.ms)
  end

  # Starts the song on the current session, the break through +lofi+'s
  # converter.
  def self.press_and_chop(lofi: :s950)
    bpm PRESS_AND_CHOP_BPM
    brk = press_and_chop_break(lofi: lofi)
    chops = press_and_chop_chops(brk)
    reese = press_and_chop_reese
    pad = press_and_chop_pad

    breaks = ->(clip) {
      clip.transpose(3).sampler(brk) { |v, s| s * v.env(0.0005, 0.01, 1, 0.006, gm: false) * (v.velocity * (1 / 0.75)) }
        .filter(:lowpass, cutoff: 13000, quality: 0.6)
    }
    bass_line = seq(F1.n2.d, F1.n8, Ab1.n8, Bb0.n1, C1.n2, Eb1.n4, Db1.n4).loop
    bass = bass_line.sampler(reese) { |v, s| s * v.env(0.01, 0.3, 0.8, 0.15, gm: false) }.filter(:lowpass, cutoff: 900, quality: 0.8)

    master { |mix| mix.limit(ceiling: -1.db) }

    bg :breaks, breaks.(chops[:full]).filter(:lowpass, cutoff: 1.n1.lfo.at(400..14000), quality: 0.8) * 4.5, fade: 0
    at_bar(5) {
      bg :breaks, breaks.(chops[:a]) * 3.6, fade: 0
      bg :bass, bass * 1.6, fade: 0
    }
    at_bar(13) {
      bg :breaks, breaks.(chops[:roll]) * 2.8, fade: 0
      stop :bass, fade: 1
      bg :pad, (pad.node * 1.6).reverb(:hall, mix: 0.3, output_channels: 2), fade: 0
    }
    at_bar(17) {
      bg :breaks, breaks.(chops[:b]) * 3.6, fade: 0
      bg :bass, bass * 1.6, fade: 0
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: PRESS_AND_CHOP_BARS,
      lofi: [:s950, Symbol, '-l', "The break's converter", [:s950, :sp1200, :mpc60, :none]],
    ) { |p| press_and_chop(lofi: p.lofi) }
  end
end
