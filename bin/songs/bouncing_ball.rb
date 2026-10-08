#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Bouncing balls: a 40-bar percussion piece (100 BPM, about 1:36) built
# from bounce rhythms, very loosely inspired by the ball-bounce
# accelerandos of Aphex Twin's "Bucephalus Bouncing Ball" (no samples or
# quotes; just the idea of drums dropped like balls).
#
# Every "ball" is MB::Sound.bounce_hits: hits whose gaps shrink by the
# ball's elasticity each bounce, so they crowd together and land exactly
# on the next bar line (back on the grid), each hit softer than the last.
# Balls loop with align: :launch, so each drops on the bar where it is
# launched, whatever its length (plain loops play in phase with the
# timeline).
# The voices map each hit's velocity (its impact speed) to loudness,
# pitch, and brightness, so a ball also drops in pitch and darkens as it
# settles.
#
# 1. Drop (bars 1-8): a kick ball every 2 bars; a metallic FM ping ball
#    every 4 bars (from bar 3) that rolls across the stereo field.
# 2. Juggling (bars 9-16): a snare ball thrown backwards (reverse: hits
#    accelerate apart, soft to loud) into each kick drop, and a hi-hat
#    ball so elastic it settles into a buzz every bar.
# 3. Grid (bars 17-24): the balls are caught by a four-on-the-floor kick
#    and eighth-note hats, while 3-beat filter-blip balls (resonant pings
#    whose pitch drops with each bounce) and a 5-beat ping ball run
#    against the bar.
# 4. Pile-up (bars 25-32): kick, snare, hat, and ping balls of 5, 3, 4,
#    and 7 beats with different elasticities, each panned along its own
#    path, drifting in and out of phase.
# 5. Settle (bars 33-40): one long ball (6 bars, 40 hits) on kick and
#    ping, settling into a buzz and silence.
#
# Usage:
#     bin/songs/bouncing_ball.rb                        # plays live in the background session
#     bin/songs/bouncing_ball.rb balls.flac             # renders to a file (-f to overwrite)
#     bin/songs/bouncing_ball.rb --room balls.flac      # with a little room reverb
#     bin/songs/bouncing_ball.rb -b 8 balls.flac        # the first section only
#     bin/songs/bouncing_ball.rb --decay speed          # every ball falls by impact speed (also gentle, none, 0.85, ...)
#
# Or in bin/sound.rb:
#     load 'bin/songs/bouncing_ball.rb'
#     bouncing_ball                                      # live (bouncing_ball(room: true))
#
# Snippets to try in bin/sound.rb:
#     # One ball: a kick dropped on a bar line, settling onto the next one
#     bg :k, bounce_hits(1.bar, count: 16, elasticity: 0.75, note: C2).loop.synth(voices: 2) { |v| v.hz.transpose(v.velocity * 12).sine * v.amp_env(0.001, 0.25, 0, 0.1) }
#     # A buzz: very elastic, many hits
#     bg :h, bounce_hits(1.bar, count: 60, elasticity: 0.93).loop.synth(voices: 2) { |v| noise.filter(:highpass, cutoff: 7000) * v.amp_env(0, 0.02, 0, 0.01) } * -6.db
#     # Loudness separate from timing: a dead ball (elasticity 0.5) keeps
#     # its bounces audible with the default decay: :gentle (e^(i/2));
#     # decay: :speed (e^i, the impact speed) fades it within four hits,
#     # and a number is a fixed fall per hit (the song's drop uses 0.9)
#     bg :k, bounce_hits(1.bar, count: 10, elasticity: 0.5, decay: :speed, note: C2).loop(align: :launch).synth(voices: 2) { |v| v.hz.transpose(v.velocity * 12).sine * v.amp_env(0.001, 0.25, 0, 0.1) }
#     # A tom ball dropping a semitone per bounce (pitch: per hit), every
#     # hit equally loud (decay: :none)
#     bg :t, bounce_hits(2.bars, count: 10, elasticity: 0.75, note: A2, pitch: -1, decay: :none).loop(align: :launch).synth(voices: 2) { |v| v.hz.sine.reset(v.trigger) * v.amp_env(0.001, 0.3, 0, 0.1) } * -6.db
#     # Thrown backwards: hits accelerate apart, soft to loud
#     bg :s, bounce_hits(2.bars, count: 12, elasticity: 0.7, reverse: true, note: D3).loop.synth(voices: 2) { |v| noise.filter(:bandpass, cutoff: 1800) * v.amp_env(0, 0.1, 0, 0.05) }
#     # Polyrhythm: a 3-beat ball against the bar.  align: :launch drops it
#     # on the bar where it launches (a plain .loop plays in phase with the
#     # timeline, so it could start part-way through a bounce)
#     bg :p, bounce_hits(3.beats, count: 10, elasticity: 0.65, note: E5).loop(align: :launch).synth(voices: 2) { |v| v.hz.sine.fm(v.hz.transpose(22.8).sine.at(700)) * v.amp_env(0, 0.4, 0, 0.2) } * -12.db
#     # The same ball dropped a beat after the next bar (rotate moves a
#     # clip's events later, wrapping around, so the end of the previous
#     # bounce settles into that beat)
#     swap :p, bounce_hits(3.beats, count: 10, elasticity: 0.65, note: E5).rotate(1.beat).loop(align: :launch)
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  BOUNCING_BALL_BARS = 40

  # Drum voices for bounce clips: each takes a Notes voice +v+ and returns
  # a node.  Hit velocity is the ball's impact speed (1 for the drop).
  BALL_VOICES = {
    # A sine kick whose pitch sweeps down on each hit and sits lower as the
    # ball settles
    kick: ->(v) {
      sweep = 1 + v.fm_env(0, 0.045, 0, 0.02) * 3
      (v.freq * sweep * (0.75 + v.velocity * 0.5)).tone.sine.reset(v.trigger).at(1.0) * v.amp_env(0.001, 0.32, 0, 0.08)
    },
    # Noise and a falling triangle, darker for softer hits
    snare: ->(v) {
      body = (v.freq * (1 + v.fm_env(0, 0.03, 0, 0.02))).tone.triangle.reset(v.trigger).at(0.5)
      snap = MB::Sound.noise.filter(:bandpass, cutoff: 900 + v.velocity * 2500, quality: 0.9)
      (body + snap) * v.amp_env(0.0005, 0.13, 0, 0.06)
    },
    # Short high noise, brighter for harder hits
    hat: ->(v) {
      MB::Sound.noise.filter(:highpass, cutoff: 4500 + v.velocity * 5000, quality: 0.8) * v.amp_env(0.0005, 0.035, 0, 0.02)
    },
    # A metallic FM ping (inharmonic ratio), dropping a few semitones as
    # the ball settles
    ping: ->(v) {
      p = v.hz.transpose(v.velocity * 5)
      p.sine.fm(p.transpose(22.8).sine.at(900) * v.fm_env(0, 0.25, 0, 0.1)) * v.amp_env(0.001, 0.5, 0, 0.25) * 0.5
    },
    # A resonant filter blip on a noise click, its pitch falling with each
    # bounce
    blip: ->(v) {
      click = MB::Sound.noise * v.amp_env(0, 0.004, 0, 0.002)
      click.filter(:bandpass, cutoff: 250 * 2**(v.velocity * 4), quality: 30) * 6
    },
  }.freeze

  # Overall level of the balls (the master bus is -10 dB).
  BALL_GAIN = 2.5

  # A bouncing-ball player: +kind+ (a BALL_VOICES key) playing +clip+
  # (looping), at +level+, panned along +pan+ (a number or node).  The
  # loop counts from its launch (align: :launch), so a ball drops exactly
  # where it is launched, whatever its length.
  def self.ball(kind, clip, level:, pan: 0.0, voices: 2)
    clip.loop(align: :launch).synth(voices: voices) { |v| BALL_VOICES.fetch(kind).(v) }.pan(pan) * (level * BALL_GAIN)
  end

  # A grid-locked player: +kind+ on a step pattern (see MB::Sound.grid).
  def self.grid_part(kind, division, pattern, note, level:, pan: 0.0)
    grid(division, pattern, value: note).loop.synth(voices: 2) { |v| BALL_VOICES.fetch(kind).(v) }.pan(pan) * (level * BALL_GAIN)
  end

  # Converts the --decay option to a bounce_hits decay: a number (e.g.
  # "0.85") or a name (speed, gentle, none, or a Curve name).
  def self.ball_decay(text)
    Float(text, exception: false) || text.to_sym
  end

  # Hit velocity falls per section (the user's picks from the 2026-10-08
  # listening test): 0.9 per hit keeps the long balls' many hits present
  # in the drop and settle; the pile-up's short balls fall by :gentle
  # (bounce_hits' default, also used for the juggling and grid balls).
  DROP_DECAY = 0.9
  PILEUP_DECAY = :gentle
  SETTLE_DECAY = 0.9

  # Starts the song on the current session (live, or inside a render
  # block).  +room+ adds a little room reverb; +decay+, if given,
  # overrides how every ball's hit velocities (loudness, pitch,
  # brightness) fall with each bounce (see MB::Sound.bounce_hits and the
  # *_DECAY constants).
  def self.bouncing_ball(room: false, decay: nil)
    bpm 100

    # Every ball's hits, with each section's loudness fall (see
    # bounce_hits; the default is :gentle), unless +decay+ overrides it
    hits = ->(length, section_decay = :gentle, **opts) { bounce_hits(length, decay: decay || section_decay, **opts) }

    # Pan paths: each ball rolls across the field over its own time
    roll = ->(length, from, to) { tween([from, to], length, curve: :sine) }

    master { |mix|
      mix = mix.reverb(:room, wet: -16.db) if room
      mix.softclip(0.5, 0.98)
    }

    # 1. Drop
    bg :kick, ball(:kick, hits.(2.bars, DROP_DECAY, count: 18, elasticity: 0.78, note: C2), level: 0.9), fade: 0
    at_bar(3) { bg :ping, ball(:ping, hits.(4.bars, DROP_DECAY, count: 20, elasticity: 0.82, note: E5), level: 0.35, pan: roll.(4.bars, -0.8, 0.8)), fade: 0 }

    # 2. Juggling
    at_bar(9) do
      bg :snare, ball(:snare, hits.(2.bars, count: 12, elasticity: 0.7, reverse: true, note: D3), level: 0.5, pan: 0.2), fade: 0
      bg :hat, ball(:hat, hits.(1.bar, count: 48, elasticity: 0.9, note: C6), level: 0.35, pan: roll.(2.bars, 0.6, -0.6)), fade: 0
    end

    # 3. Grid
    at_bar(17) do
      stop :kick, fade: 0
      stop :snare, fade: 0
      stop :ping, fade: 0
      bg :kick, grid_part(:kick, 4, 'xxxx', C2, level: 0.75), fade: 0
      bg :hat, grid_part(:hat, 8, 'x.xXx.xx', C6, level: 0.3, pan: -0.3), fade: 0
      bg :blip, ball(:blip, hits.(3.beats, count: 10, elasticity: 0.65, note: 60), level: 0.4, pan: roll.(3.beats, 0.7, -0.7)), fade: 0
      bg :ping, ball(:ping, hits.(5.beats, count: 12, elasticity: 0.7, note: B4), level: 0.3, pan: 0.5), fade: 0
    end

    # 4. Pile-up
    at_bar(25) do
      bg :kick, ball(:kick, hits.(5.beats, PILEUP_DECAY, count: 14, elasticity: 0.72, note: C2), level: 0.85, pan: roll.(5.beats, -0.3, 0.3)), fade: 0
      bg :snare, ball(:snare, hits.(3.beats, PILEUP_DECAY, count: 10, elasticity: 0.6, reverse: true, note: D3), level: 0.45, pan: roll.(3.beats, 0.5, -0.5)), fade: 0
      bg :hat, ball(:hat, hits.(4.beats, PILEUP_DECAY, count: 36, elasticity: 0.88, note: C6), level: 0.3, pan: roll.(4.beats, -0.7, 0.7)), fade: 0
      bg :ping, ball(:ping, hits.(7.beats, PILEUP_DECAY, count: 16, elasticity: 0.8, note: G5), level: 0.3, pan: roll.(7.beats, 0.8, -0.8)), fade: 0
      stop :blip, fade: 0
    end

    # 5. Settle
    at_bar(33) do
      [:kick, :snare, :hat, :ping].each { |n| stop n, fade: 0 }
      long = hits.(6.bars, SETTLE_DECAY, count: 40, elasticity: 0.88, note: C2)
      bg :kick, ball(:kick, long, level: 0.9), fade: 0
      bg :ping, ball(:ping, hits.(6.bars, SETTLE_DECAY, count: 40, elasticity: 0.88, note: E5), level: 0.3, pan: roll.(6.bars, -0.8, 0.8)), fade: 0
    end
    at_bar(39) { outro fade: 1 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: BOUNCING_BALL_BARS,
      room: [false, 'Add a little room reverb'],
      decay: [nil, String, 'Override how hit velocities fall per bounce in every section: speed (e^i), gentle (e^(i/2)), none, or a factor like 0.85 (default: 0.9 per hit for the drop and settle, gentle elsewhere)'],
    ) { |p| bouncing_ball(room: p.room, decay: p.decay && ball_decay(p.decay)) }
  end
end
