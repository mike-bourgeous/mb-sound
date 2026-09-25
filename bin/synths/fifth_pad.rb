#!/usr/bin/env ruby
# A two-voice root + fifth pad patch for sequences: two slightly detuned saws
# per interval, slow swells that overlap between chords, a lowpass that opens
# with each chord, and a little Haas stereo width.  Returns a stereo pair of
# graph nodes.
#
# Run directly to hear a demo:
#     bin/synths/fifth_pad.rb [bpm]
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
  #             next chord's attack (see Sequence::Clip#synth).
  # +:cutoff+ - Lowpass cutoff in Hz (the filter opens to 1.5x with each chord).
  # +:detune+ - Semitones between each saw pair (0.07 is about 7 cents).
  # +:attack+, +:release+ - Swell times in seconds.
  # +:width+ - Seconds to delay the right channel (0 for mono).
  def self.fifth_pad(clip, voices: 2, cutoff: 1400, detune: 0.07, attack: 0.6, release: 2.5, width: 0.012)
    saws = ->(c) { c.tone.ramp.at(0.5) + c.transpose(detune).tone.ramp.at(0.5) }

    pad = clip.synth(voices: voices) { |v|
      swell = v.env(attack, 1.0, 0.8, release)
      bloom = v.env(attack * 1.5, 2.0, 0.3, release)

      ((saws.(v) + saws.(v.transpose(7)) * 0.7) * swell * 0.35)
        .filter(:lowpass, cutoff: cutoff * 0.5 + cutoff * bloom, quality: 0.9)
    }.softclip(0.4, 0.9)

    [pad, pad.delay(seconds: width)]
  end

  if $0 == __FILE__
    bpm(Float(ARGV[0] || 90))
    play fifth_pad(seq(A2, F2, C3, G2).n1.legato(0.95).loop)
  end
end
