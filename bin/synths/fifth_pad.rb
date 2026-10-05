#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A two-voice root + fifth pad patch for sequences: two slightly detuned saws
# per interval, slow swells that overlap between chords, a lowpass that opens
# with each chord, and a little Haas stereo width.  Returns a stereo pair of
# graph nodes.
#
# Run directly to hear a demo (--help for all options):
#     bin/synths/fifth_pad.rb                    # plays live until Ctrl-C
#     bin/synths/fifth_pad.rb --bpm 70 pad.flac  # renders 8 bars at 70 BPM
#
# Or load it in bin/sound.rb and apply it to your own sequences:
#     load 'bin/synths/fifth_pad.rb'
#     chords = seq(A2, F2, C3, G2).n1.legato(0.95).loop
#     bg :pad, fifth_pad(chords)
#     bg :pad, fifth_pad(chords, cutoff: 900, detune: 0.12)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # +:voices+ - Number of voices, so each chord's release rings under the
  #             next chord's attack (see Sequence::Clip#synth; two spare
  #             voices take over when a new chord steals a ringing one).
  # +:cutoff+ - Lowpass cutoff in Hz (the filter opens to 1.5x with each chord).
  # +:detune+ - Semitones between each saw pair (0.07 is about 7 cents).
  # +:attack+, +:release+ - Swell times in seconds.
  # +:width+ - Seconds to delay the right channel (0 for mono).
  def self.fifth_pad(clip, voices: 2, cutoff: 1400, detune: 0.07, attack: 0.6, release: 2.5, width: 0.012)
    saws = ->(pitch) { pitch.ramp.at(0.5) + pitch.transpose(detune).ramp.at(0.5) }

    # Slow-first curves (attack, decay, release) with 0.68x the attack and
    # 0.9x the release time swell and fade like the smoothstep envelopes
    # this patch was written with (times to -20/-6 dB rising and -6/-20 dB
    # falling within about 5%), so +:attack+ and +:release+ keep their sound.
    curve = [-21, -12, -6]

    pad = clip.synth(voices: voices) { |v|
      swell = v.amp_env(attack * 0.68, 1.0, 0.8, release * 0.9, sensitivity: -6.db..0.db, curve: curve)

      # From half the cutoff up to 1.5x (log2(3) octaves above it), settling
      # at 0.8x (0.5 * 3 ** 0.43; the old linear sweep's 0.5 + 0.3)
      bloom = v.filt_env(attack * 1.5 * 0.68, 2.0, 0.43, release * 0.9, depth: Math.log2(3), curve: curve)

      ((saws.(v.hz) + saws.(v.hz.transpose(7)) * 0.7) * swell * 0.35)
        .filter(:lowpass, cutoff: v.cutoff(cutoff * 0.5, env: bloom, keytrack: 0), quality: 0.9)
    }.softclip(0.4, 0.9)

    [pad, pad.delay(width)]
  end

  if main_script?(__FILE__)
    song_script(bars: 8) {
      bpm 90
      bg :pad, fifth_pad(seq(A2, F2, C3, G2).n1.legato(0.95).loop), fade: 0
    }
  end
end
