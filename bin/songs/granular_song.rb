#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 21-bar ambient demo of granular synthesis and spectral time-stretching
# at 72 BPM (design/notes/granular.md).  Every sound starts as a short
# Sample made in the script; grains and stretches turn them into a piece
# in D minor over a G drone.
#
# 1. "drone" (bars 1-21): one singing-bowl strike (inharmonic partials,
#    1.6 s, on G) frozen into a drone: grains of 220 ms read around 12%
#    into the strike (`position: 0.12`, ± 3%), a fifth and an octave
#    below sprayed in (`pitch: [0, -12, 7]`), spread across the stereo
#    field; at bar 17 it moves down a fourth to D (IV -> I).
# 2. "rain" (bars 3-12, back for the close at 16): 1.5 s of synthetic
#    rain (random filtered drops) scanned at a quarter speed (`scan:
#    0.25`) as a cloud of short percussive grains (`window: :expodec`),
#    pitched ± 5 semitones, a third of them backwards, through a
#    ping-pong delay (a dotted eighth left, a quarter right, darkening
#    repeats) and a hall.
# 3. "voice" (bars 5-21): a one-bar sung vowel phrase (a formant voice
#    gliding A3 → C4 → E4 → D4) stretched 8x: bars 5-12 the phase vocoder
#    (`stretch(8, mode: :spectral)`: the notes keep their pitch and
#    vowels, two bars each), bars 13-21 Paulstretch (`mode: :paul`: the
#    phrase coming back dissolved into a wash, its resolving D carried
#    over the drone's D into the outro).
# 4. "spray" (bars 9-18): the pad chord (Dm7) played as tempo-locked
#    regular grains (four per beat, `jitter: 0`) sprayed over the octave
#    and twelfth (`pitch: [0, 12, 19]`), the position sweeping through the
#    chord once every 4 bars, moving through i - iv - v - i (Dm7, Gm7 at
#    +5, Am7 at +7, Dm7) two bars each.
#
# Usage:
#     bin/songs/granular_song.rb                     # plays live in the background session
#     bin/songs/granular_song.rb granular.flac       # renders to a file instead (-f to overwrite)
#     bin/songs/granular_song.rb -p rain out.flac    # one part alone (drone, rain, voice, spray)
#     bin/songs/granular_song.rb --help              # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/granular_song.rb'
#     granular_song                                  # live (granular_song(part: :rain) etc.)
#
# Snippets to try in bin/sound.rb (help :granular has more):
#     pad = bounce(1.bar) { (220.hz.ramp + 277.2.hz.ramp + 330.hz.ramp).lp4(1800) * 0.3 }
#     bg :g, pad.grains(position: 0.5, size: 150.ms, density: 30) * -16.db              # frozen
#     bg :g, pad.grains(scan: 0.1, size: 80.ms, density: 60, pan_spread: 1) * -16.db    # 10x slower, smeared
#     knob :pos, 0.5, range: 0..1
#     bg :g, pad.grains(position: knob(:pos), size: 60.ms, density: 50) * -16.db       # scrub with turn :pos, 0.9, over: 2
#     bg :g, pad.grains(pitch: [0, 12, 19], window: :expodec, density: 1.n16, jitter: 0) * -16.db   # rhythmic spray
#     bg :g, pad.grains(size: 5.ms, density: 400, pitch_spread: 12, read: :drop) * -20.db           # lofi fizz
#     bg :g, midi.synth(voices: 4) { |v| v.grains(pad, density: 40, size: 70.ms) * v.env(0.2, 0.3, 0.8, 1.2) } * -16.db
#     bg :s, pad.stretch(8, mode: :spectral).node * -12.db   # phase vocoder
#     bg :s, pad.stretch(8, mode: :paul).node * -12.db       # Paulstretch
#     bg :s, pad.stretch(8).node * -12.db                    # the cyclic S950 stretch, for comparison
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  GRANULAR_SONG_BARS = 21

  # The song's tempo (the sources are bounced at it: the Session's own
  # tempo change lands later, so `bpm 72` alone left them at 120).
  GRANULAR_SONG_BPM = 72

  # The song's sources, made from numbers (seeded): [bowl, rain, voice,
  # pad] Samples, the voice and pad bounced at +bpm+.
  def self.granular_song_sources(seed: 1, bpm: GRANULAR_SONG_BPM)
    r = Random.new(seed)
    sr = 48000

    # A singing bowl: inharmonic partials with their own decays and a slow
    # beat between near-twin modes
    n = (1.6 * sr).round
    t = Numo::DFloat.new(n).seq / sr
    bowl = [[1.0, 1.0, 1.4], [1.003, 0.6, 1.3], [2.71, 0.5, 0.8], [5.15, 0.25, 0.45], [8.43, 0.12, 0.25]].sum { |ratio, amp, decay|
      Numo::NMath.sin(t * (2 * Math::PI * 196 * ratio)) * (Numo::NMath.exp(-t / decay) * amp)
    }
    bowl = Sample[bowl * 0.5, name: 'bowl']

    # Rain: random drops, each a short decaying chirp
    n = (1.5 * sr).round
    rain = Numo::DFloat.zeros(n)
    260.times do
      at = r.rand(n - 2000)
      f = 1500 + r.rand * 5000
      a = 0.05 + r.rand**3 * 0.6
      len = 300 + r.rand(900)
      i = Numo::DFloat.new(len).seq
      rain[at...(at + len)] += Numo::NMath.sin(i * (2 * Math::PI * f / sr) * (1 + i / len * 0.3)) * Numo::NMath.exp(-i / (len / 5.0)) * a
    end
    rain = Sample[rain, name: 'rain']

    phrase = seq(A3.n4, C4.n4, E4.n4, D4.n4).legato(1)
    voice = bounce(1.bar, bpm: bpm, name: 'voice') {
      v = phrase.notes
      v.hz.glide(60.ms).vibrato(5.2, depth: 0.25).ramp.formant(:a, :o, morph: 0.5.hz.lfo.at(0..1)) * v.amp_env(0.08, 0.2, 0.9, 0.2) * 0.5
    }

    pad = bounce(1.bar, bpm: bpm, name: 'pad') {
      [D3, A3, C4, F4].map { |p| p.unison(3, detune: 10.cents) }.reduce(:+).lp4(2200, resonance: 0.2) * 0.12
    }

    [bowl, rain, voice, pad]
  end

  def self.granular_song(part: :all, density: 1.0)
    tempo = bpm(GRANULAR_SONG_BPM)
    bowl, rain, voice, pad = granular_song_sources(bpm: tempo)

    # The bowl drone, on G (+pitch+ 0) or moved down a fourth to D (-5):
    # the closing IV -> I
    drone = ->(pitch) {
      bowl.grains(
        position: 0.12, spread: 0.03, size: 220.ms, density: 22 * density, pitch: [0, -12, 7].map { |p| p + pitch },
        pitch_spread: 0.08, pan_spread: 0.9, seed: 1
      ) * -11.db
    }

    # Rain through a darker dotted-eighth / quarter ping-pong and a hall
    cloud = rain.grains(
      scan: 0.25, size: 40.ms, density: 120 * density, pitch_spread: 5, reverse: 0.35, window: :expodec, pan_spread: 1, seed: 2
    ).lp4(7000).delay(per_channel(1.n8.dotted, 1.n4), feedback: 0.45, dry: 1, wet: -5.db) { |fb| fb.filter(:lowpass, cutoff: 2500) }
      .reverb(:hall, wet: -16.db) * 1.db

    sung_pv = voice.stretch(8, mode: :spectral).node.pan(-0.2) * -1.db
    sung_paul = voice.stretch(8, mode: :paul, window: 0.4.seconds).node.pan(0.2) * -1.db

    # The pad (Dm7) as tempo-locked grains, moved by +pitch+ semitones
    # (5: Gm7, 7: Am7)
    spray = ->(pitch) {
      pad.grains(
        position: 4.bars.hz.phasor * 0.8 + 0.1, size: 90.ms, density: 1.n16, jitter: 0,
        pitch: [0, 12, 19].map { |p| p + pitch }, window: :tukey, pan_spread: 0.7, seed: 3
      ) * -1.db
    }

    master { |mix| mix.reverb(:hall, wet: -10.db) }

    case part
    when :drone then bg :drone, drone.(0), fade: 0
    when :rain then bg :rain, cloud, fade: 0
    when :voice
      bg :voice, sung_pv, fade: 0
      at_bar(9) { bg :voice, sung_paul, fade: 0.5 }
    when :spray then bg :spray, spray.(0), fade: 0
    else
      # The sung phrase (A C E D, two bars a note), then the pad's chords
      # i - iv - v - i (Dm7 Gm7 Am7 Dm7) under its Paulstretched echo;
      # the close calls back to the opening: the drone alone with the
      # rain, moving from G down to D (IV -> I), under the echo's last
      # note, the D, carried into the outro
      bg :drone, drone.(0), fade: 0
      at_bar(3) { bg :rain, cloud, fade: 1 }
      at_bar(5) { bg :voice, sung_pv, fade: 0 }
      at_bar(9) { bg :spray, spray.(0), fade: 1 }
      at_bar(11) { bg :spray, spray.(5), fade: 0.25 }
      at_bar(12) { stop :rain, fade: 1 }
      at_bar(13) do
        bg :voice, sung_paul, fade: 0.5
        bg :spray, spray.(7), fade: 0.25
      end
      at_bar(15) { bg :spray, spray.(0), fade: 0.25 }
      at_bar(16) { bg :rain, cloud, fade: 1 }
      at_bar(17) do
        bg :drone, drone.(-5), fade: 1
        stop :spray, fade: 2
      end
      at_bar(19) { outro fade: 2 }
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: GRANULAR_SONG_BARS,
      part: [:all, Symbol, '-p', 'The parts to play', [:all, :drone, :rain, :voice, :spray]],
      density: [1.0, Float, '-d', 'Grain density scale', 0.1..4.0],
    ) { |p| granular_song(part: p.part, density: p.density) }
  end
end
