#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Wind Chimes": a texture study (textures-1, 2026-10-14) for dust, drift,
# and the modal resonators.  About a minute and a half at 60 BPM (a bar is
# four seconds), in D, on the yo pentatonic (D E G A B).  Everything is one
# random wind: a slow drift (`gust`) sets the wind's noise band, its
# loudness, and how often each chime is struck, so the chimes ring hardest
# when the wind blows hardest.
#
#   weather  1-4   rain on leaves (dust drops pinged at random pitches over
#                  a soft hiss) and wind (noise through a drifting bandpass)
#   chimes   5-12  five wind chimes (resonate :chime, aluminum tubes), each
#                  struck by its own dust whose rate follows the gust,
#                  swinging in the wind: a slow pan sway whose width
#                  follows the gust, with the strikes bunched where each
#                  swing turns around (twice a swing)
#   bowls    9-18  a singing bowl and a rin struck now and then, and a
#                  wine glass rubbed by quiet noise (resonate :glass) that
#                  swells with the gust
#   wood    13-20  a marimba figure (resonate :marimba in a synth voice)
#                  through tape wow and flutter (a delay drifting a few
#                  milliseconds), with a little vinyl crackle
#   still   21-24  the wind dies; the last chimes and bowls ring out
#
# Usage:
#     bin/songs/wind_chimes.rb                    # plays live
#     bin/songs/wind_chimes.rb chimes.flac        # renders 24 bars (-f to overwrite): seed 1, gusty 2
#     bin/songs/wind_chimes.rb -s 7 chimes.flac   # another wind (random seed; 1 by default)
#     bin/songs/wind_chimes.rb -G 1 chimes.flac   # calmer (gusty 2 by default: chimes struck twice as often
#                                                 # as at 1, with a darker roar under the wind)
#   (The maintainer's Bench pick, 2026-10-15: seed 1 at -G 2.)
#     bin/songs/wind_chimes.rb --stems stems/ chimes.flac   # with each part alone
#
# Or in bin/sound.rb:
#     load 'bin/songs/wind_chimes.rb'
#     wind_chimes                                 # plays the parts as players (rain, wind, chimes, bowls, wood; gusty: 2)
#
# Snippets to try in bin/sound.rb:
#     # One chime in the wind
#     gust = drift(0.2, range: 0..1, walk: 0.4)
#     bg :c, dust(gust * 4 + 0.2, range: 0.2..1).resonate(:chime, 880).at(-14.db)
#     # A rubbed glass that swells with the wind
#     bg :g, (noise.at(0.0004) * drift(0.15, range: 0.2..1)).resonate(:glass, 1175, spread: 0.7).at(-10.db)
#     # Swap the object: every preset at the same strike
#     %i[bowl rin gong bell chime bar marimba vibes glass plate membrane].each_with_index { |p, i| at_bar(i + 1) { bg :o, impulse.resonate(p, 330).at(-12.db) } }
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The chimes' pitches (the yo pentatonic, high).
  WIND_CHIMES_NOTES = [D5, E5, G5, A5, B5].freeze

  # Rain on leaves: drops pinged at random pitches over a soft hiss.
  # +rate+ drops per second; stereo, each side its own drops.
  def self.wind_chimes_rain(rate: 120)
    side = ->(pan) {
      drops = dust(rate, range: 0.05..1)
      pitch = noise.sample_hold(drops).at(2200..6500)
      (drops.ping(pitch, decay: 0.015) * 0.1 + noise.lp4(2500).at(-34.db)).pan(pan)
    }
    side.(-0.6) + side.(0.6)
  end

  # Wind: noise through a bandpass whose center and level follow +gust+
  # (a node from 0 to 1).  Gustier winds (+gusty+ above 1) add a dark roar
  # under it, brown-ish noise (white noise through a 12 dB/octave lowpass
  # at 380 Hz) swelling with the square of the gust, so the strongest gusts
  # sound strong (at a steady 0.8 gust, -G 2 is 3.3 LU louder than -G 1,
  # -G 3 7.5 LU) (textures-2, 2026-10-15; the maintainer: "Gustier
  # should mix in a bit of pink or brown noise maybe to make the wind more
  # intense to match?").
  def self.wind_chimes_wind(gust, gusty: 1.0)
    band = noise.filter(:bandpass, cutoff: gust * 1100 + 250, quality: 2.5)
    air = band * (gust * 0.85 + 0.15)
    roar = gusty > 1 ? noise.filter(:lowpass, cutoff: 380, quality: 0.5) * (gust * gust * [gusty - 1, 2].min * 3.0) : nil
    (roar ? air + roar : air).pan(drift(0.1, walk: 0.3) * 0.5)
  end

  # Five chimes, each struck by its own dust at a rate following +gust+
  # (+gusty+ scales it) times +gate+ (0 strikes none), spread across the
  # field and swinging: each chime sways on its own slow pendulum (0.5 to
  # 0.8 swings a second), the sway as wide as the gust, and is struck
  # mostly as its swing turns around at either end (the strike rate times
  # 0.2 + 1.6 sin^2 of the swing, twice a swing, averaging the same
  # density; textures-2, the maintainer's idea of a pan LFO that matches
  # or doubles the strike density's variation).
  def self.wind_chimes_chimes(gust, gate, gusty: 1.0)
    WIND_CHIMES_NOTES.each_with_index.map { |note, i|
      swing = (0.5 + 0.075 * i).hz.lfo.with_phase(i * 0.29)
      ends = swing * swing * 1.6 + 0.2
      strikes = dust((gust * gate * (1.6 * gusty) + gate * 0.05) * ends, range: 0.15..1)
      strikes.resonate(:chime, note, decay: 5).pan(swing * gust * 0.3 + (i * 0.4 - 0.8))
    }.sum
  end

  # A bowl (D3) and a rin (A4) struck now and then while +gate+ is open,
  # and a rubbed glass (D6) swelling with +gust+.
  def self.wind_chimes_bowls(gust, gate)
    bowl = dust(gate * 0.25, range: 0.5..1).resonate(:bowl, D3, spread: 0.5)
    rin = dust(gate * 0.18, range: 0.3..0.8).resonate(:rin, A4, spread: 0.7) * 0.6
    glass = (noise.at(0.0003) * (gust * 0.8 + 0.2) * gate).resonate(:glass, D6, spread: 0.8) * 0.5
    bowl + rin + glass
  end

  # A marimba figure through tape wow and flutter, with vinyl crackle.
  def self.wind_chimes_wood
    figure = seq(D4, A4, B4, A4, E4, G4, Rest, D4, A4, D5, B4, Rest).n8.loop
    marimba = figure.synth(voices: 4) { |v| v.trigger.resonate(:marimba, v.freq) }
    wow = drift(0.7, smooth: :cosine).at(0.004..0.007) + 6.5.hz.lfo.at(-0.00008..0.00008)
    crackle = dust(25, bipolar: true).filter(:highpass, cutoff: 1500) * 0.06
    (marimba.delay(wow) * 0.7 + crackle).pan(drift(5.seconds, smooth: :cosine) * 0.5)
  end

  # A gain from 0, rising over +fade+ bars from bar +from+, falling over
  # +fade+ bars to 0 at bar +to+, then 0 (the song's sections).
  def self.wind_chimes_section(from, to, fade: 1)
    len = ->(bars) { bars > 0 ? bars.bars : 0 }
    env([[0, 0], [0, len.(from - 1)], [1, len.(fade), 0], [1, len.(to - from - 2 * fade)], [0, len.(fade), 0]], hold_last: true)
  end

  # The piece's parts as named stereo graphs (all following one wind, a
  # node they share, so they start together and play to the end).
  def self.wind_chimes_parts(gusty: 2.0)
    gust = drift(0.12, range: 0..1, walk: 0.35)
    wind = gust * wind_chimes_section(1, 23, fade: 2) # the wind dies over bars 21-22

    {
      rain: (wind_chimes_rain * wind_chimes_section(1, 20, fade: 2)).at(6.db),
      wind: wind_chimes_wind(wind, gusty: gusty).at(-2.db),
      chimes: wind_chimes_chimes(wind, wind_chimes_section(5, 22, fade: 1), gusty: gusty).at(-6.db),
      bowls: wind_chimes_bowls(wind, wind_chimes_section(9, 19, fade: 1)).at(-2.db),
      wood: (wind_chimes_wood * wind_chimes_section(13, 21, fade: 1)).at(-4.db),
    }
  end

  # Plays the piece on the current session.
  def self.wind_chimes(gusty: 2.0)
    bpm 60
    wind_chimes_parts(gusty: gusty).each { |name, part| bg name, part, fade: 0 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: 24,
      seed: [1, 'random seed (each seed is another wind)', '-s', Integer, 0..1_000_000],
      gusty: [2.0, 'how often the wind strikes the chimes (scale; above 1 adds a roar)', '-G', Float, 0.1..5],
    ) { |p|
      MB::Sound.seed(p.seed)
      wind_chimes(gusty: p.gusty)
    }
  end
end
