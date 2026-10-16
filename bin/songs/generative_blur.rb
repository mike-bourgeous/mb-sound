#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Blur you can hear (the generative layer; design/notes/generative.md):
# a blurred probability scale leaks a little weight to the semitones next
# to its notes, so "wrong" notes sometimes win.  In a sparse melody that is
# a rare passing color; here every note is a fresh draw from the field, many
# times a second, so the blur's share of wrong notes is easy to hear.
#
# The field: D dorian for 6 bars, blending into F major over bars 7-10,
# then back to D dorian over bars 11-16 (looping every 16 bars), plus the
# chord of the moment (two bars each) weighted 1.5, blurred by -u, over
# A3..A5 with a bell around E4.
#   dense   a sixteenth-note line: every sixteenth a note drawn from the
#           field by weight (strikes with chance 1, gap 1), a soft
#           triangle pluck in a small room
#   grains  a granular cloud of one sustained tone (a second of triangle
#           and octave sine on D4): every grain starts on a note-on of a
#           generator drawing a note from the field by weight (about 8 a
#           second, Poisson-like: chance 0.7 per thirty-second), and plays
#           at that note's pitch, so each grain's pitch is one draw from
#           the probability scale
#   -c dense  a much denser cloud: about 40 grains a second (chance 0.9
#           per 128th), 350 ms each, so about 14 overlap, spread wider in
#           the tone and across the stereo field
#   -t 1    shorter key changes: F major lands on bar 9 (the B flat chord)
#           and D dorian comes back on bar 13 (the G7), each blended over
#           the 1 bar before it (-t 0: a step), instead of the slow 4- and
#           6-bar blends
#   -B      the anchor (--bass): one note a bar, the chord's root two
#           octaves under the line with a quieter fifth, never blurred, a
#           warm triangle/sine with a little low-passed saw, so the chord
#           and key changes are heard under the blur
#
# Usage:
#     bin/songs/generative_blur.rb                            # dense, blur 0.15, live
#     bin/songs/generative_blur.rb -u 0 blur.flac             # no blur: only scale and chord notes
#     bin/songs/generative_blur.rb -u 0.4 blur.flac           # many wrong notes
#     bin/songs/generative_blur.rb -m grains -u 0.4 blur.flac # the granular cloud
#     bin/songs/generative_blur.rb -m both blur.flac          # both together
#     bin/songs/generative_blur.rb -n 64 -u 0.15 blur.flac    # sixty-fourths: about 22 draws a second
#     bin/songs/generative_blur.rb -n 64 -u 0.03 -B -C 0.5 blur.flac   # light blur, chords blending over half a bar
#     bin/songs/generative_blur.rb -n 64 -u 0.03 -B -O 3 blur.flac     # three octaves (A3..A6)
#     bin/songs/generative_blur.rb -m dense -n 64 -u 0.15 --bass blur.flac           # 64ths over the bassline
#     bin/songs/generative_blur.rb -m grains -c dense -t 1 -u 0.15 --bass blur.flac  # a thick cloud, 1-bar key changes, bassline
#     bin/songs/generative_blur.rb -m both -n 64 -c dense -t 1 -u 0.15 --bass blur.flac
#
# Or in bin/sound.rb:
#     load 'bin/songs/generative_blur.rb'
#     generative_blur(mode: :grains, blur: 0.3)
#     generative_blur(mode: :grains, cloud: :dense, transition: 1, bass: true, blur: 0.15)
#
# Snippets (after `load 'bin/songs/generative_blur.rb'`):
#     f = (scale(:dorian, :d).weights.blur(0.3) + chord(:min7, root: :d).weights).over(A3..A5, around: E4, width: 7)
#     puts f                                                  # the field as a bar chart: the blurred semitones are the short bars
#     line = strikes(f, every: 1.n16, chance: 1, gap: 1, sharpen: 1)
#     bg :dense, line.synth(voices: 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) }.at(-18.db)
#     n = strikes(f, every: 1.n32, chance: 0.7, gap: 1, sharpen: 1).notes
#     tone = bounce(1.seconds, root: D4) { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
#     bg :cloud, tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.3, size: 150.ms, normalize: false).at(-12.db)
#     bg :bass, generative_blur_bass_clip.synth(voices: 4) { |v| (v.hz.triangle * 0.5 + v.hz.sine * 0.6) * v.env(0.03, 1.5, 0.55, 0.5) * v.velocity }.at(-12.db)

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/ambient'

module MB::Sound
  # The piece's length in bars (the field loops every 16).
  GENERATIVE_BLUR_BARS = 16

  # The field's chords, two bars each (D dorian, into F major, back).
  GENERATIVE_BLUR_CHORDS = [
    [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [F3, A3, C4, E4],
    [As2, D3, F3, A3], [C3, E3, G3, As3], [G2, B2, D3, F3], [A2, C3, E3, G3],
  ].freeze

  # The probability field at +blur+ (a FieldTimeline over A3..A5).  With
  # +transition+ nil, the key blends from D dorian into F major over bars
  # 7-10 and back over bars 11-16; with a number of bars, F major lands on
  # bar 9 (the B flat chord) and D dorian comes back on bar 13 (the G7),
  # each change blended over the +transition+ bars before it (0: a step).
  # +chord_blend+ nil or 0 steps from chord to chord; a number of bars
  # (up to 2) blends each chord into the next over that span before it.
  # +octaves+ 2 (A3..A5, a bell around E4) or 3 (A3..A6, around B4, a
  # wider bell).
  def self.generative_blur_field(blur, transition: nil, chord_blend: nil, octaves: 2)
    dorian = scale(:dorian, :d)
    major = scale(:major, :f)
    key =
      if transition.nil?
        harmony(0 => dorian, 6.bars => dorian, 10.bars => major, loop: 16.bars)
      elsif transition == 0
        harmony(0 => dorian, 8.bars => major, 12.bars => dorian, curve: :step, loop: 16.bars)
      else
        t = transition.rationalize
        harmony(0 => dorian, (8 - t).bars => dorian, 8.bars => major, (12 - t).bars => major, 12.bars => dorian, loop: 16.bars)
      end
    chords =
      if chord_blend.nil? || chord_blend == 0
        harmony(GENERATIVE_BLUR_CHORDS.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 16.bars)
      else
        b = chord_blend.rationalize
        raise ArgumentError, "chord_blend must be 0..2 bars (got #{chord_blend})" unless b > 0 && b <= 2
        keys = GENERATIVE_BLUR_CHORDS.each_with_index.flat_map { |c, i| b < 2 ? [[(2 * i).bars, c], [(2 * i + 2 - b).bars, c]] : [[(2 * i).bars, c]] }
        harmony(keys.to_h, loop: 16.bars)
      end
    range, around, width = octaves == 3 ? [A3..A6, B4, 10.5] : [A3..A5, E4, 7]
    ((blur > 0 ? key.blur(blur) : key) + chords * 1.5).over(range, around: around, width: width)
  end

  # The anchor bassline: one note a bar, the root of the chord of the
  # moment two octaves below the line's middle (G1..F2), with a quieter
  # fifth above it, never blurred, so every chord and key change is heard.
  def self.generative_blur_bass_clip
    roots = GENERATIVE_BLUR_CHORDS.flat_map { |c| [c.first.dn] * 2 }
    (seq(*roots).n1.vel(0.8) & seq(*roots.map { |r| r.transpose(7) }).n1.vel(0.45)).loop
  end

  # Starts the piece on the current session (live, or in a render block).
  # +mode+ :dense, :grains, or :both; +blur+ 0..1; +seed+ the draws.
  # +division+ the dense line's notes per whole note (16: sixteenths, 64:
  # sixty-fourths, about 22 notes a second at 84 BPM).  +bass+ adds the
  # anchor bassline (#generative_blur_bass_clip).  +cloud+ :sparse (about 8
  # grains a second) or :dense (about 40 a second, longer, overlapping,
  # spread wider).  +transition+ the bars over which the key changes (nil:
  # the original slow blends; see #generative_blur_field).  +chord_blend+
  # the bars over which each chord blends into the next (nil: steps).
  # +octaves+ 2 or 3 (the field's range; see #generative_blur_field).
  def self.generative_blur(mode: :dense, blur: 0.15, seed: 3, division: 16, bass: false, cloud: :sparse, transition: nil,
                           chord_blend: nil, octaves: 2)
    bpm 84
    field = generative_blur_field(blur, transition: transition, chord_blend: chord_blend, octaves: octaves)

    if mode == :dense || mode == :both
      line = strikes(field, every: Rational(1, division).whole, chance: 1, gap: 1, sharpen: 1, velocity: 0.45..0.8, seed: seed)
      pluck = line.synth(voices: division > 16 ? division / 2 : 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) * (v.velocity * 0.6 + 0.4) }
      bg :dense, ambient_room(pluck.lp4(3500), space: 0.35, decay: 3, room_size: 0.5).pan(-0.1), fade: 0
    end

    if mode == :grains || mode == :both
      if cloud == :dense
        # About 40 grains a second (chance 0.9 per 128th), 350 ms each, so
        # about 14 overlap; spread over a 3 s tone so even grains pitched
        # up to A5 read inside it.
        tone = bounce(3.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
        n = strikes(field, every: Rational(1, 128).whole, chance: 0.9, gap: 1, sharpen: 1, seed: seed + 1).notes
        cloud_node = tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.5, spread: 0.2, size: 350.ms,
          pan_spread: 1, normalize: false, seed: seed + 2)
        bg :grains, ambient_room(cloud_node.lp4(4500) * 0.2, space: 0.4, decay: 3, room_size: 0.8), fade: 0
      else
        tone = bounce(1.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
        n = strikes(field, every: 1.n32, chance: 0.7, gap: 1, sharpen: 1, seed: seed + 1).notes
        cloud_node = tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.3, spread: 0.1, size: 150.ms,
          pan_spread: 0.8, normalize: false, seed: seed + 2)
        bg :grains, ambient_room(cloud_node.lp4(4000) * 0.3, space: 0.5, decay: 5, room_size: 0.8), fade: 0
      end
    end

    if bass
      low = generative_blur_bass_clip.synth(voices: 4) { |v|
        body = v.hz.triangle * 0.5 + v.hz.sine * 0.6 + v.hz.saw.lp4(v.freq * 3) * 0.25
        body * v.env(0.03, 1.5, 0.55, 0.5) * v.velocity
      }
      bg :bass, ambient_room(low, space: 0.12, decay: 1.5, room_size: 0.3).at(-3.db), fade: 0
    end

    master { |mix| (mix * (bass ? 3.db : 6.db)).limit }
  end

  if main_script?(__FILE__)
    song_script(
      bars: GENERATIVE_BLUR_BARS,
      mode: [:dense, Symbol, '-m', 'dense (a sixteenth-note line), grains (a cloud), or both', [:dense, :grains, :both]],
      blur: [0.15, Float, '-u', 'How far the scale blurs into wrong notes', 0.0..1.0],
      seed: [3, Integer, '-s', 'The seed of the draws', 0..1_000_000],
      division: [16, Integer, '-n', 'Notes per whole note in the dense line (16, 32, 64)', [8, 16, 32, 64]],
      bass: [false, '-B', 'Add the anchor bassline: one unblurred root (and fifth) a bar, following the chords'],
      cloud: [:sparse, Symbol, '-c', 'The granular cloud: sparse (about 8 grains a second) or dense (about 40, longer, overlapping)', [:sparse, :dense]],
      transition: [nil, Float, '-t', 'Bars over which the key changes (F major on bar 9, D dorian on bar 13; 0 a step; default: the slow 4- and 6-bar blends)', 0.0..4.0],
      chord_blend: [nil, Float, '-C', 'Bars over which each chord blends into the next (default: steps)', 0.0..2.0],
      octaves: [2, Integer, '-O', 'The line\'s range: 2 (A3..A5) or 3 octaves (A3..A6)', [2, 3]],
    ) { |p|
      generative_blur(mode: p.mode, blur: p.blur, seed: p.seed, division: p.division, bass: p.bass, cloud: p.cloud, transition: p.transition,
        chord_blend: p.chord_blend, octaves: p.octaves)
    }
  end
end
