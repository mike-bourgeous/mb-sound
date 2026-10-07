#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of tweening curves (MB::Sound::Curve) at 96 BPM: glide
# shapes, tweened automation, and curves as shapers.
#
# 1. "swarm" (bars 1-8): a melody played by a 10-copy swarm whose copies
#    glide with their own shapes and wiggles: squiggles and elastic springs
#    alternating copy by copy (`shape: channels(:squiggle, :elastic)`), so
#    each note arrives as a wobbling smear that settles in tune.
# 2. "pad" (bars 1-16): a D minor pad with an elastic filter sweep (the
#    cutoff tweens to each new value with a springy overshoot, once a bar)
#    and a bouncing detune (the unison spread falls onto each value like a
#    ball, every 2 bars).  From bar 9 an "anticipate" pump (a phasor per
#    beat through Curve[:anticipate]) makes it wind up before each beat.
# 3. "bass" (bars 9-16): stepped automation (the cutoff climbs in 8 steps
#    per bar, `curve: :steps`) and an odd waveshaper: the bass through
#    `ease(:elastic, symmetric: true)`, whose ringing transfer curve folds
#    the wave into bright, vocal harmonics (antialiased, like softclip).
# 4. "ball" (bars 5-16): a bouncing ball every 2 bars.  The hit times are
#    the contact points of Curve[:bounce] (a curve turned into a rhythm),
#    and each hit's pitch and level fall with the bounce heights.
#
# Usage:
#     bin/songs/tween_song.rb                     # plays live in the background session
#     bin/songs/tween_song.rb tween.flac          # renders to a file instead (-f to overwrite)
#     bin/songs/tween_song.rb -p pad tween.flac   # one part alone (swarm, pad, bass, ball)
#     bin/songs/tween_song.rb --help              # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/tween_song.rb'
#     tween_song                                  # live (tween_song(part: :ball) etc.)
#
# Snippets to try in bin/sound.rb (see also bin/plot_curves.rb):
#     # Swarm squiggle glides from a MIDI keyboard: every note wobbles into tune
#     bg :sw, midi.synth(voices: 1) { |v| v.hz.swarm(10, glide: spread(40.ms..600.ms), shape: :squiggle, cycles: 3..6) * v.amp_env } * -6.db
#     # The same melody with plain, squiggle, elastic, and bouncing glides
#     mel = seq(A3, C4, E4, D4, G3, C4).n4.loop
#     bg :g, mel.synth(voices: 1) { |v| v.hz.swarm(8, glide: spread(60.ms..500.ms), shape: :bounce) * v.amp_env } * -9.db
#     # An elastic filter sweep: the cutoff springs to each value
#     bg :pad, D3.unison(7, detune: 15.cents).filter(:lowpass, cutoff: tween([400.hz, 3000.hz, 800.hz, 2000.hz], 1.bar, curve: :elastic), quality: 4) * -15.db
#     # Bouncing detune: the unison spread drops onto each value like a ball
#     bg :pad, D3.unison(7, detune: tween([0.02, 0.4], 2.bars, curve: :bounce)) * -15.db
#     # Stepped automation: 8 steps a bar up to each value
#     bg :b, A1.saw.filter(:lowpass, cutoff: tween([200.hz, 2400.hz], 1.bar, curve: :steps, cycles: 8), quality: 6) * -12.db
#     # An elastic knob: the mod wheel springs instead of gliding
#     bg :k, midi.synth { |v| v.hz.saw.filter(:lowpass, cutoff: 300 + midi.mod.smooth(300.ms, curve: :elastic) * 4000) * v.amp_env } * -9.db
#     # Odd uses: a sine through bouncing and staircase transfer curves (waveshapers)
#     bg :ws, 110.hz.ease(:bounce, symmetric: true) * -12.db
#     bg :ws, 110.hz.ease(Curve.steps(6, :sine), range: -1..1) * -12.db
#     # An LFO reshaped into a bouncing ball, and a stepped gate (exact: aease)
#     bg :lfo, 220.hz.saw.filter(:lowpass, cutoff: 2.bars.hz.phasor.aease(:bounce, out: 3000..300), quality: 5) * -12.db
#     bg :gate, 110.hz.square * 1.bar.hz.phasor.aease(:steps, cycles: 16, edges: :wrap) * -12.db
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  TWEEN_SONG_BARS = 16

  # The contact times (fractions of the fall) and heights before each
  # contact of Curve.bounce(overshoot:, cycles:): the fall, then each
  # bounce (restitution sqrt(overshoot)).
  def self.bounce_contacts(overshoot, bounces)
    r = Math.sqrt(overshoot)
    t0 = 1.0 / (1.0 + 2.0 * (1..bounces).sum { |i| r**i })
    times = [t0]
    heights = [1.0]
    (1..bounces).each do |i|
      times << times.last + 2 * t0 * r**i
      heights << r**(2 * i)
    end
    [times, heights]
  end

  # Starts the song on the current session (live, or inside a render
  # block).  +part+ is :all, :swarm, :pad, :bass, or :ball.
  def self.tween_song(part: :all, copies: 10)
    bpm 96

    # 1. A swarm melody with per-copy glide shapes
    melody = seq(
      D4.n4, F4.n8, A4.n8, G4.n4.d, rest.n8,
      E4.n4, G4.n8, F4.n8, D4.n2,
      A3.n4, D4.n8, F4.n8, C5.n4, A4.n4,
      Bb4.n4.d, A4.n8, G4.n4, E4.n4,
    ).legato(0.95).loop
    swarm = melody.synth(voices: 1) { |v|
      v.hz.swarm(
        copies, detune: 8.cents, glide: spread(80.ms..700.ms), shape: channels(:squiggle, :elastic), overshoot: 0.08..0.2, cycles: 2..5,
        drift: 4.cents, seed: 5
      ) * v.amp_env(0.04, 0.4, 0.8, 0.5)
    }
    swarm = swarm.filter(:lowpass, cutoff: 3200, quality: 0.8) * 0.45

    # 2. A pad with an elastic filter sweep and a bouncing detune (made
    # twice: plain, then pumped; the tweens follow the timeline, so both
    # line up)
    make_pad = -> {
      # Pitches tween in octaves: a linear elastic tween from 3400 to 700 Hz
      # would overshoot below 0 Hz
      cutoff = tween([500.hz, 2600.hz, 900.hz, 3400.hz, 700.hz, 2000.hz, 1200.hz, 4200.hz], 1.bar, curve: :elastic, overshoot: 0.35, cycles: 3)
      detune = tween([0.02, 0.35, 0.08, 0.5], 2.bars, curve: :bounce)
      pad = [D3, F3, A3, D4].map { |n| n.unison(5, detune: detune, spread: 1) }.reduce(:+)
      pad.filter(:lowpass, cutoff: cutoff, quality: 3) * 0.12
    }
    pad = make_pad.()
    pump = 1.beat.hz.phasor.aease(:anticipate, overshoot: 0.25, out: 0.35..1)
    pumped = make_pad.() * pump

    # 3. Bass: stepped automation and an elastic waveshaper
    bassline = seq(D2, D2, F2, D2, C2, C2, A1, C2).n4.legato(0.8).loop
    bass = bassline.synth(voices: 1) { |v| v.hz.saw.at(0.8) * v.amp_env(0.005, 0.2, 0.6, 0.1) }
    bass = bass.ease(:elastic, symmetric: true, overshoot: 0.5, cycles: 4)
    bass = bass.filter(:lowpass, cutoff: tween([250.hz, 2800.hz, 400.hz, 1800.hz], 1.bar, curve: :steps, cycles: 8), quality: 4) * 0.14

    # 4. A bouncing ball every 2 bars: Curve[:bounce]'s contacts as hits
    times, heights = bounce_contacts(0.55, 9)
    fall = 2r # whole notes (2 bars of 4/4) from the drop to the last contact
    hits = times.zip(heights).map { |t, h|
      Sequence::Event.new(start: (t * 0.9 * fall).rationalize(1/10_000r), length: 1/64r, value: 84 - (1 - h) * 14, velocity: 0.2 + 0.8 * h)
    }
    ball_clip = Sequence::Clip.new(hits, length: fall, loop: true)
    ball = ball_clip.synth(voices: 2) { |v| v.hz.sine * v.amp_env(0.001, 0.12, 0, 0.05) + v.hz.transpose(19).sine.at(0.3) * v.amp_env(0.0005, 0.04, 0, 0.02) }
    ball = ball.pan(0.3) * 0.6

    master { |mix| mix.reverb(:hall, wet: -14.db).softclip(0.6, 0.98) }

    case part
    when :swarm then bg :swarm, swarm, fade: 0
    when :pad then bg :pad, pumped, fade: 0
    when :bass then bg :bass, bass, fade: 0
    when :ball then bg :ball, ball, fade: 0
    else
      bg :swarm, swarm, fade: 0
      bg :pad, pad, fade: 0
      at_bar(5) { bg :ball, ball, fade: 0 }
      at_bar(9) do
        stop :swarm, fade: 1
        bg :pad, pumped, fade: 0.5
        bg :bass, bass, fade: 0
      end
      at_bar(15) { outro fade: 2 }
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: TWEEN_SONG_BARS,
      part: [:all, Symbol, '-p', 'The parts to play', [:all, :swarm, :pad, :bass, :ball]],
      copies: [10, Integer, '-c', 'Copies in the swarm', 1..32],
    ) { |p| tween_song(part: p.part, copies: p.copies) }
  end
end
