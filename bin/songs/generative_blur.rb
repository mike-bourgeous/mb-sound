#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Blur you can hear (the generative layer; design/notes/generative.md):
# a blurred probability scale leaks a little weight to the semitones next
# to its notes, so "wrong" notes sometimes win.  In a sparse melody that is
# a rare passing color; here every note is a fresh draw from the field, many
# times a second, so the blur's share of wrong notes is easy to hear.
#
# The field: D dorian for 6 bars, blending into F major over bars 7-10,
# then back to D dorian over bars 11-16 (looping every 16 bars; -t changes
# this), plus the chord of the moment (two bars each, each blending into
# the next over the -C bars before it) weighted 1.5, blurred by -u (3% by
# default), over A3..A5 with a bell around E4 (-O 3: A3..A6 around B4).
#   dense   a sixteenth-note line: every sixteenth a note drawn from the
#           field by weight (strikes with chance 1, gap 1), a soft
#           triangle pluck in a small room; chords blend over 1/4 bar
#   grains  a granular cloud of one sustained tone (a triangle and octave
#           sine on D4): every grain starts on a note-on of a generator
#           drawing a note from the field by weight, and plays at that
#           note's pitch, so each grain's pitch is one draw from the
#           probability scale; 120 grains a second (-c 120, below), 117
#           ms each, so about 14 overlap, spread wide in the tone and
#           across the stereo field, over three octaves, chords blending
#           over 1/2 bar, the key changing over 1 bar (below)
#   both    the two together (the key changes over 1 bar for both, so they
#           agree on the key; ranges and chord blends stay per part)
#   -c dense   the cloud before omnibus9: about 40 grains a second
#           (chance 0.9 per 128th), 350 ms each
#   -c sparse  the earliest, thinner cloud: about 8 grains a second
#           (Poisson-like: chance 0.7 per thirty-second), 150 ms each
#   -c 60   any number of grains a second (0.5 to 160; 120 by default), on the dense
#           cloud's tone: the strike chance per 128th (44.8 a second at 84
#           BPM; 256ths or 512ths above 40 a second, keeping the chance at
#           most 0.9) hits that rate, grains last 350 ms up to 40 a second
#           and 14/rate seconds above (about 14 overlapping, under the
#           32-grain limit), and the level scales by sqrt(14 / overlap) (at
#           most one grain's worth), so thinner clouds aren't much quieter
#           (#generative_blur_cloud_settings)
#   -t 1    shorter key changes (the cloud's default): F major lands on bar
#           9 (the B flat chord) and D dorian comes back on bar 13 (the G7),
#           each blended over the 1 bar before it (-t 0: a step; -t slow:
#           the 4- and 6-bar blends, the line's default)
#   bass    the anchor (on by default; --no-bass leaves it out): one note a
#           bar, the chord's root two octaves under the line with a quieter
#           fifth, never blurred, a warm triangle/sine with a little
#           low-passed saw, so the chord and key changes are heard under
#           the blur
#
# The defaults are the maintainer's Listening Bench picks (2026-10-16:
# blur 1-5%, the bass anchor, a 1/4-bar chord blend for the line, and
# "cloud, 3 octaves, 1/2-bar blend"; 2026-10-17, fixes-prepanel-1: -c 120
# over dense, 15, and 60).  The earlier defaults (blur 0.15, no
# bass, chord steps, two octaves, the slow key blends, a sparse cloud) are
# still there with explicit options:
#     bin/songs/generative_blur.rb -n 16 -u 0.15 --no-bass -C 0 blur.flac                        # the old dense line
#     bin/songs/generative_blur.rb -m grains -u 0.15 --no-bass -c sparse -t slow -C 0 -O 2 blur.flac  # the old cloud
#     bin/songs/generative_blur.rb -m grains -c dense blur.flac   # the 40-a-second cloud (the default before omnibus9)
#
# Usage:
#     bin/songs/generative_blur.rb                            # dense 64ths (about 22 draws a second), blur 0.03, bass, live
#     bin/songs/generative_blur.rb -u 0 blur.flac             # no blur: only scale and chord notes
#     bin/songs/generative_blur.rb -u 0.4 blur.flac           # many wrong notes
#     bin/songs/generative_blur.rb -n 16 blur.flac            # sixteenths instead of sixty-fourths
#     bin/songs/generative_blur.rb -C 0 blur.flac             # chords stepping instead of blending
#     bin/songs/generative_blur.rb -O 3 -C 0.5 blur.flac      # three octaves (A3..A6), chords blending over half a bar
#     bin/songs/generative_blur.rb -m grains blur.flac        # the granular cloud, 120 grains a second
#     bin/songs/generative_blur.rb -m grains -u 0.4 -c sparse --no-bass blur.flac  # a thin cloud, many wrong notes, no anchor
#     bin/songs/generative_blur.rb -m grains -c 60 blur.flac  # 60 grains a second (233 ms each)
#     bin/songs/generative_blur.rb -m grains -c 15 blur.flac  # 15 a second, between sparse and dense
#     bin/songs/generative_blur.rb -m both blur.flac          # both together
#
# Or in bin/sound.rb:
#     load 'bin/songs/generative_blur.rb'
#     generative_blur(mode: :grains)
#     generative_blur(mode: :grains, cloud: :sparse, transition: :slow, bass: false, blur: 0.3)
#     generative_blur(mode: :grains, cloud: 60)                  # 60 grains a second
#     generative_blur(mode: :grains, cloud: :dense)              # about 40 a second, 350 ms each (before omnibus9)
#
# Snippets (after `load 'bin/songs/generative_blur.rb'`):
#     f = (scale(:dorian, :d).weights.blur(0.3) + chord(:min7, root: :d).weights).over(A3..A5, around: E4, width: 7)
#     puts f                                                  # the field as a bar chart: the blurred semitones are the short bars
#     line = strikes(f, every: 1.n16, chance: 1, gap: 1, sharpen: 1)
#     bg :dense, line.synth(voices: 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) }.at(-18.db)
#     g = generative_blur_field(0.03, transition: 1, chord_blend: 0.5, octaves: 3)   # the cloud's field over 16 bars
#     n = strikes(g, every: Rational(1, 128).whole, chance: 0.9, gap: 1, sharpen: 1).notes
#     tone = bounce(3.seconds, root: D4) { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
#     bg :cloud, tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.5, spread: 0.2, size: 350.ms, pan_spread: 1, normalize: false).at(-24.db)
#     bg :bass, generative_blur_bass_clip.synth(voices: 4) { |v| (v.hz.triangle * 0.5 + v.hz.sine * 0.6) * v.env(0.03, 1.5, 0.55, 0.5) * v.velocity }.at(-12.db)

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/ambient'

module MB::Sound
  # The piece's length in bars (the field loops every 16).
  GENERATIVE_BLUR_BARS = 16

  # The generators are library entries (lib-gen-1; defined in
  # lib/mb/sound/library/generators/generative_blur.rb, the field and the
  # cloud settings there as Library::Generators::GenerativeBlur): the line
  # L.gen.blur_line and the cloud's strikes L.gen.blur_cloud.

  # The probability field at +blur+ (see
  # Library::Generators::GenerativeBlur.field).
  def self.generative_blur_field(blur, transition: nil, chord_blend: nil, octaves: 2)
    Library::Generators::GenerativeBlur.field(blur, transition: transition, chord_blend: chord_blend, octaves: octaves)
  end

  # The anchor bassline: one note a bar, the root of the chord of the
  # moment two octaves below the line's middle (G1..F2), with a quieter
  # fifth above it, never blurred, so every chord and key change is heard.
  def self.generative_blur_bass_clip
    roots = Library::Generators::GenerativeBlur.chord_list.flat_map { |c| [c.first.dn] * 2 }
    (seq(*roots).n1.vel(0.8) & seq(*roots.map { |r| r.transpose(7) }).n1.vel(0.45)).loop
  end

  # Default settings per part, the tempo, and the cloud rates (see
  # Library::Generators::GenerativeBlur).
  GENERATIVE_BLUR_DEFAULTS = Library::Generators::GenerativeBlur::DEFAULTS
  GENERATIVE_BLUR_BPM = Library::Generators::GenerativeBlur::BPM
  GENERATIVE_BLUR_CLOUD_RATES = Library::Generators::GenerativeBlur::CLOUD_RATES

  # The strike grid, chance, grain size (seconds), and gain of a cloud of
  # +rate+ grains a second (see
  # Library::Generators::GenerativeBlur.cloud_settings).
  def self.generative_blur_cloud_settings(rate)
    Library::Generators::GenerativeBlur.cloud_settings(rate)
  end

  # Starts the piece on the current session (live, or in a render block).
  # +mode+ :dense, :grains, or :both; +blur+ 0..1; +seed+ the draws.
  # +division+ the dense line's notes per whole note (16: sixteenths, 64:
  # sixty-fourths, about 22 notes a second at 84 BPM).  +bass+ the anchor
  # bassline (#generative_blur_bass_clip; false leaves it out).  +cloud+
  # :dense (about 40 grains a second, long, overlapping, spread wide),
  # :sparse (about 8 a second), or a number of grains a second (see
  # #generative_blur_cloud_settings).  +transition+ the bars over which the key
  # changes (:slow: the original 4- and 6-bar blends; see
  # #generative_blur_field).  +chord_blend+ the bars over which each chord
  # blends into the next (0: steps).  +octaves+ 2 or 3 (the field's range).
  # Each of the last three, nil, is the part's default
  # (GENERATIVE_BLUR_DEFAULTS).
  #
  # Before defaults-1 (2026-10-16) the defaults were blur 0.15, no bass, a
  # sparse cloud, slow key blends, chord steps, and two octaves for both
  # parts: `generative_blur(blur: 0.15, bass: false, cloud: :sparse,
  # transition: :slow, chord_blend: 0, octaves: 2)` plays that again.
  def self.generative_blur(mode: :dense, blur: 0.03, seed: 3, division: 64, bass: true, cloud: 120, transition: nil,
                           chord_blend: nil, octaves: nil)
    bpm GENERATIVE_BLUR_BPM
    numeric_cloud = cloud.is_a?(Numeric) ? generative_blur_cloud_settings(cloud) : nil
    unless numeric_cloud || cloud == :dense || cloud == :sparse
      raise ArgumentError, "cloud is :dense, :sparse, or grains a second (got #{cloud.inspect})"
    end
    raise ArgumentError, "mode is :dense, :grains, or :both (got #{mode.inspect})" unless [:dense, :grains, :both].include?(mode)
    transition ||= mode == :both ? 1 : GENERATIVE_BLUR_DEFAULTS[mode][:transition]
    unless transition == :slow || (transition.is_a?(Numeric) && transition >= 0)
      raise ArgumentError, "transition is :slow or a number of bars (got #{transition.inspect})"
    end
    field_for = ->(part) {
      d = GENERATIVE_BLUR_DEFAULTS[part]
      generative_blur_field(blur, transition: transition, chord_blend: chord_blend || d[:chord_blend], octaves: octaves || d[:octaves])
    }

    if mode == :dense || mode == :both
      line = L.gen.blur_line(seed: seed, harmony: field_for.(:dense), division: division)
      pluck = line.synth(voices: division > 16 ? division / 2 : 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) * (v.velocity * 0.6 + 0.4) }
      bg :dense, ambient_room(pluck.lp4(3500), space: 0.35, decay: 3, room_size: 0.5).pan(-0.1), fade: 0
    end

    if mode == :grains || mode == :both
      if numeric_cloud
        # The dense cloud's tone and spread at another rate (see
        # #generative_blur_cloud_settings)
        c = numeric_cloud
        tone = bounce(3.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
        n = L.gen.blur_cloud(seed: seed + 1, harmony: field_for.(:grains), every: Rational(1, c[:division]).whole, chance: c[:chance]).notes
        cloud_node = tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.5, spread: 0.2, size: c[:size],
          pan_spread: 1, normalize: false, seed: seed + 2)
        bg :grains, ambient_room(cloud_node.lp4(4500) * c[:gain], space: 0.4, decay: 3, room_size: 0.8), fade: 0
      elsif cloud == :dense
        # About 40 grains a second (chance 0.9 per 128th), 350 ms each, so
        # about 14 overlap; spread over a 3 s tone so even grains pitched
        # up to A5 read inside it.
        tone = bounce(3.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
        n = L.gen.blur_cloud(seed: seed + 1, harmony: field_for.(:grains), every: Rational(1, 128).whole, chance: 0.9).notes
        cloud_node = tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.5, spread: 0.2, size: 350.ms,
          pan_spread: 1, normalize: false, seed: seed + 2)
        bg :grains, ambient_room(cloud_node.lp4(4500) * 0.2, space: 0.4, decay: 3, room_size: 0.8), fade: 0
      else
        tone = bounce(1.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
        n = L.gen.blur_cloud(seed: seed + 1, harmony: field_for.(:grains), every: 1.n32, chance: 0.7).notes
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
      blur: [0.03, Float, '-u', 'How far the scale blurs into wrong notes', 0.0..1.0],
      seed: [3, Integer, '-s', 'The seed of the draws', 0..1_000_000],
      division: [64, Integer, '-n', 'Notes per whole note in the dense line (16, 32, 64)', [8, 16, 32, 64]],
      bass: [true, '-B', 'The anchor bassline: one unblurred root (and fifth) a bar, following the chords (--no-bass leaves it out)'],
      cloud: [120, ->(s) {
        next s.to_sym if s == 'dense' || s == 'sparse'
        rate = Float(s, exception: false)
        unless rate && GENERATIVE_BLUR_CLOUD_RATES.cover?(rate)
          raise ArgumentError, "must be sparse, dense, or grains a second from #{GENERATIVE_BLUR_CLOUD_RATES.begin} to #{GENERATIVE_BLUR_CLOUD_RATES.end}"
        end
        rate
      }, '-c', 'The granular cloud: grains a second (0.5..160; 120: 117 ms each), dense (the earlier default: about 40 a second, 350 ms, overlapping), or sparse (about 8)'],
      transition: [nil, ->(s) { s == 'slow' ? :slow : Float(s).tap { |t| raise ArgumentError, 'must be slow or 0..4' unless (0..4).cover?(t) } }, '-t',
        'Bars over which the key changes (F major on bar 9, D dorian on bar 13; 0 a step), or slow (the 4- and 6-bar blends); ' \
        'default: slow for the line, 1 for the cloud and both'],
      chord_blend: [nil, Float, '-C', 'Bars over which each chord blends into the next (0 steps; default: 0.25 for the line, 0.5 for the cloud)', 0.0..2.0],
      octaves: [nil, Integer, '-O', 'The range: 2 (A3..A5) or 3 octaves (A3..A6) (default: 2 for the line, 3 for the cloud)', [2, 3]],
    ) { |p|
      generative_blur(mode: p.mode, blur: p.blur, seed: p.seed, division: p.division, bass: p.bass, cloud: p.cloud, transition: p.transition,
        chord_blend: p.chord_blend, octaves: p.octaves)
    }
  end
end
