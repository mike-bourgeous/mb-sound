#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# A slowly shifting stereo drone: phase-modulated tones on B, D#, E, and F#
# fading in and out on slow LFOs, with filtered noise and a short
# modulated delay on each side.  Plays until Ctrl-C.
#
# Usage:
#     bin/songs/stereo_drone.rb                  # plays live until Ctrl-C
#     bin/songs/stereo_drone.rb drone.flac       # renders 30 bars (60 seconds)
#     bin/songs/stereo_drone.rb -b 60 drone.flac # renders 60 bars
#     bin/songs/stereo_drone.rb --help           # all options
#
# Notes follow the session tuning live.  To hear the drone retune in the
# middle, add this line to the song block (B4 = 480 Hz is 60 fps friendly):
#     at_bar(9) { tuning b4: 480 }

require 'bundler/setup'
require 'mb-sound'

# Running inside MB::Sound makes note names like B1, #stereo, #bg, etc.
# available just like in bin/sound.rb.
module MB::Sound
  # Phase-modulated tones on +notes+ (Notes or other Pitches), each fading
  # in and out in turn over +interval+ seconds.
  def self.toneseq(interval, *notes)
    phase = -2.0 * Math::PI / notes.length
    lfo_freq = 1.0 / interval

    notes.map.with_index { |note, idx|
      fade = lfo_freq.hz.triangle.at(-90..-12).with_phase(Math::PI * 0.25 + phase * idx).db
      modulator = (note.freq * 2.hz.lfo.at(2.98..3.02)).tone.at(2) * (lfo_freq / 2 + lfo_freq / notes.count * idx).hz.lfo.at(0..1)

      fade * note.sine.pm(modulator)
    }
  end

  song_script(bars: 30) {
    q = 0.5 * toneseq(12, B1, Ds2, E2).sum

    # Alternating notes go left and right
    left_tones, right_tones = toneseq(32, Fs3, Ds3, Fs3, E3, Fs4, Ds4, Fs4, E4).each_slice(2).to_a.transpose

    noise = (1.hz.noise.at(0.1) * 0.056.hz.lfo.at(-20..-10).db * B1.at(-2..1)).filter(:lowpass, cutoff: 0.082.hz.lfo.at(300..2200), quality: 2)

    # DSL calls on a stereo bundle run per channel; the noise is inverted on
    # the right
    drone = (stereo(0.3 * left_tones.sum, 0.3 * right_tones.sum) + q + stereo(noise, noise * -1))
      .softclip(0.6)
      .oversample(2)
      .delay(
        seconds: stereo(0.4.hz.lfo.at(0..0.013), 0.3.hz.lfo.at(0..0.02)),
        feedback: -0.5, dry: 1, smoothing: false
      )
      .softclip(0.8)

    bg :drone, drone, fade: 0
  }
end
