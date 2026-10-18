#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# The session key and keyboard locks (midi-consol-2): a phrase "mashed" on
# every key, white and black, played through a lock style while the key
# changes and a knob walks the mode from bright to dark.
#
# Styles (-s): mash (every key a scale degree, flowing; black keys silent),
# play (degrees fitted to the octave, the root on every C; black keys
# passing notes), along (the nearest scale note), chord (the current
# chord's tones, extended above; chords from a progression in the key),
# off (the phrase as played).
#
# The song: bars 1-4 in -k (D dorian), bars 5-8 in Bb lydian (`key :bb,
# :lydian` on bar 5), bars 9-16 with `mode knob(:dark)` walking from Lydian
# to Locrian one note at a time over 8 bars.
#
# Usage:
#     bin/midi/key_lock.rb                        # plays live (style play)
#     bin/midi/key_lock.rb -s mash out.flac
#     bin/midi/key_lock.rb -s chord -k a,minor out.flac
#
# Snippets for bin/sound.rb (a keyboard on the console's MIDI port; the
# computer keyboard too, `ui.keys`):
#     key :d, :dorian
#     lock :play                  # black keys are passing notes
#     lock :mash                  # everything you hit is in key
#     lock :chord, from: [1, 6, 4, 5], bass: :root_fifth
#     knob :dark, 0; mode knob(:dark); turn :dark, 1, over: 8
#     lock :off

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Lock styles of bin/midi/key_lock.rb.
  KEY_LOCK_STYLES = [:mash, :play, :along, :chord, :off].freeze

  # Every key from C3 up two octaves, in a mashing order: runs, leaps, and
  # black keys.
  def self.key_lock_phrase
    keys = (48..71).to_a
    order = keys.each_slice(4).flat_map { |a, b, c, d| [a, c, b, d, c, a] }
    seq(*order).n16.loop
  end

  # Starts the song on the current session.
  def self.key_lock(style: :play, root: :d, mode: :dorian)
    bpm 100
    key root, mode
    knob :dark, 0

    lock = style == :chord ? { from: [1, 6, 4, 5], bass: :root_fifth } : {}
    keys = key_lock_phrase.stream.lock(style, **lock)
    # (C on every C is the key's root with lock :play: the bass follows the key)
    bass = seq(C2, C2, C2, C2).n4.loop.stream.lock(:play)
    voice = proc { |v|
      (v.hz.ramp + v.hz.transpose(0.08).ramp)
        .filter(:lowpass, cutoff: v.cutoff(1200, env: v.filt_env(0.001, 0.25, 0.2, 0.2, depth: 2)), quality: 1.2) *
        v.amp_env(0.003, 0.3, 0.3, 0.2) * 0.12
    }
    master { |mix| mix.reverb(:hall, wet: -12.db).softclip(0.6, 0.98) }

    bg :keys, keys.synth(voices: 10, &voice), fade: 0
    bg :bass, bass.synth(voices: 2) { |v| v.hz.triangle * v.amp_env(0.005, 0.4, 0.5, 0.2) * 0.3 }, fade: 0
    at_bar(5) { key :bb, :lydian }
    at_bar(9) {
      mode knob(:dark)
      turn :dark, 1, over: 8
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: 16,
      style: [:play, Symbol, '-s', 'The lock style', KEY_LOCK_STYLES],
      key: ['d,dorian', String, '-k', 'The starting key: root,mode'],
    ) { |p|
      root, mode = p.key.split(',', 2)
      key_lock(style: p.style, root: root.to_sym, mode: (mode || :major).to_sym)
    }
  end
end
