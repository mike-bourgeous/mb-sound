#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# "Critters": a house fly and a mouse loose around your head (textures-4,
# 2026-10-15), a texture study for drift paths that drive a sound.  Two or
# three drifts are a critter's position in meters (x right, y ahead, z up,
# you at 0, 0, 0); the distance gives the delay (doppler: nearing raises
# the pitch, leaving lowers it), an air lowpass, and the level; x / r is
# the pan, or with --binaural each ear's own delay and head shadow.
#
# The fly's wings follow its effort (speed and climbing, from its own
# path): harder strokes beat a little faster, swing wider (louder), and
# are brighter.  Its spectrum turns with its heading: the wingbeat
# fundamental radiates like a dipole along the body (loudest ahead of and
# behind the fly), the second harmonic like a monopole (all around), and
# wind from the wing vortices trails behind it (Sueur, Tuck & Robert 2005,
# a tethered blowfly; see design/notes/textures.md for the sources).
# The mouse dashes and stops, its feet scratching in short bursts at the
# fastest part of each dash, and squeaks now and then: tonal
# chirps 3-6 kHz, each 80-300 ms with its own pitch contour (rising,
# falling, or arched) and a fast vibrato.
#
# Usage:
#     bin/songs/critters.rb                         # plays live (both critters)
#     bin/songs/critters.rb critters.flac           # renders 8 bars (32 s; -f to overwrite)
#     bin/songs/critters.rb -c fly fly.flac         # only the fly (or -c mouse)
#     bin/songs/critters.rb --binaural fly.flac     # headphones: per-ear delays and head shadow,
#                                                   # and the critters can pass behind you
#     bin/songs/critters.rb -D 1 fly.flac           # real doppler (5x by default, for drama)
#     bin/songs/critters.rb -S 1 fly.flac           # doppler smoothing in Hz (1.5 by default): lower swoops gentler,
#     bin/songs/critters.rb -S 0 fly.flac           # and 0 is unsmoothed: every dart warbles
#     bin/songs/critters.rb -s 7 fly.flac           # another flight (seed; 5 by default)
#
# Or in bin/sound.rb:
#     load 'bin/songs/critters.rb'
#     critters                                      # both, as players :fly and :mouse
#     critters(:fly, binaural: true)
#     critters(:fly, smooth: 1.3)                   # gentler doppler swoops (1.5 Hz by default)
#
# Snippets to try in bin/sound.rb:
#     # A fly on a fixed course: a slow circle around your head
#     x = 0.1.hz.lfo.sine.at(2); y = 0.1.hz.lfo.sine.with_phase(0.25).at(2)
#     bg :f, critter_place(critter_fly(x, y, 0.constant), x, y, 0.constant, binaural: true)
#     # Only the wings, cruising (effort 0.2) or darting (1)
#     bg :w, critter_wings(0.2.constant, 0.constant).at(-12.db)
#     # One mouse squeak every second
#     bg :m, critter_squeaks(dust(1, range: 1..1, min_gap: 900.ms)).at(-12.db)
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Head radius (m) and speed of sound (m/s) for --binaural (Brown & Duda's
  # spherical head).
  CRITTER_HEAD = 0.0875
  CRITTER_SOUND_SPEED = 343.0

  # A fly's path: x (left/right), y (ahead; behind too with +behind+), z
  # (up/down) in meters, darting with elastic overshoots and random holds.
  def self.critter_fly_path(behind: false)
    x = drift(1.5, range: -3..3, walk: 0.6, hold: 30.ms..300.ms, jitter: 0.5, smooth: Curve[:elastic, overshoot: 0.4])
    y = drift(1, range: behind ? -2.5..2.5 : 0.3..2.5, walk: 0.5, smooth: :cosine)
    z = drift(0.7, range: -0.6..1.2, walk: 0.4, hold: 0.1..0.6, smooth: :cosine)
    [x, y, z]
  end

  # The mouse's path on the floor (z 0): dashes and stops.  One random
  # gate (+go+: moving about half the time, in runs of a fraction of a
  # second to a few seconds) runs both drifts' clocks, so x and y stop
  # together; its lowpass is the mouse speeding up and slowing down.
  # (textures-5, 2026-10-16; the maintainer: "Scratches only immediately
  # during movement?"  Rounds 3 and 4 scurried with elastic overshoots and
  # never really stopped: under 0.1 m/s 3% of the time, 1.2 m/s median,
  # and jittered short steps sped up to tens of meters per second.)
  def self.critter_mouse_path(behind: false)
    go = (drift(1.5, smooth: :step, jitter: 0.8).aclip(0, 0.02) * 50).filter(:lowpass, cutoff: 6, quality: 0.5)
    x = drift(go * 2.2, range: -2..2, walk: 0.4, smooth: :cubic)
    y = drift(go * 1.6, range: behind ? -2..2 : 0.4..2, walk: 0.4, smooth: :cubic)
    [x, y, 0.constant]
  end

  # Velocity (m/s per axis) of a path, from 20 ms differences (0 for the
  # first 20 ms, while the delays still hold zeros: otherwise a critter
  # would start at tens of meters per second, and the mouse scratch).
  def self.critter_velocity(path)
    path.map { |c| (c - c.delay(20.ms)) * silence(0.02).and_then(50.constant) }
  end

  # A fly's wings at +effort+ (a node 0..1: cruising to darting) and
  # +heading+ (a node -1..1: the cosine between its flight and the line
  # from you to it; -1 flying at you, 1 flying away).  +wing+ Hz at rest
  # (house flies: about 190 Hz), up to +lift+ semitones faster at full
  # effort.
  def self.critter_wings(effort, heading, wing: 190, lift: 1)
    pitch = wing.hz.transpose(effort * lift + drift(5, walk: 0.5).at(0.25))
    # The saw's fundamental is 2/pi of a sine in phase with it (Tone#saw),
    # so adding (dipole - 1) * 2/pi of the sine sets the fundamental alone.
    dipole = heading.aabs * 0.7 + 0.3
    stroke = pitch.saw + pitch.sine * ((dipole - 1) * (2 / Math::PI)) + pitch.transpose(12).sine * 0.25
    stroke = stroke.lp4(effort * 4000 + 1800) * (effort * 0.55 + 0.45) * drift(25).at(0.85..1)
    vortex = noise(:pink).filter(:bandpass, cutoff: 1800, quality: 0.7) * effort * (heading.aclip(0, 1) * 0.8 + 0.2) * 0.35
    stroke + vortex
  end

  # A fly flying along +x+, +y+, +z+ (nodes, meters; see
  # #critter_fly_path), its wings following its effort (speed over 5 m/s
  # plus climbing over 2 m/s, smoothed at 4 Hz) and heading.  Mono;
  # #critter_place puts it around you.
  def self.critter_fly(x, y, z, wing: 190)
    vx, vy, vz = critter_velocity([x, y, z])
    speed = (vx * vx + vy * vy + vz * vz) ** 0.5
    effort = (speed / 5 + vz.aclip(0, 2) / 2).aclip(0, 1).filter(:lowpass, cutoff: 4)
    heading = (vx * x + vy * y + vz * z) / (speed * (x * x + y * y + z * z) ** 0.5 + 0.01)
    critter_wings(effort, heading, wing: wing)
  end

  # Mouse squeaks on each impulse of +trigger+: tonal chirps around 3-6
  # kHz, 80-300 ms long, each with its own pitch contour (a slope of -8 to
  # +8 semitones over the squeak plus an arch of -4 to +9 in the middle),
  # a fast vibrato (30-45 Hz, a quarter semitone), and a quiet second
  # harmonic.  The trigger's height is the loudness.
  def self.critter_squeaks(trigger)
    held = ->(range) { noise.sample_hold(trigger).at(range) }
    length = held.(0.08..0.3)
    base = held.(-4.0..4.0)
    slope = held.(-8.0..8.0)
    arch = held.(-4.0..9.0)
    # (each ends its first segment on the hold, so neither sustains)
    ramp = env([[1, length, 0], [1, 0.1]], trigger: trigger, hold: length).no_velocity # back to 0 after the squeak
    bump = env([[1, length * 0.5, -6], [0, length * 0.5, 6]], trigger: trigger, hold: length * 0.5).no_velocity
    vibrato = 37.hz.transpose(held.(-3.5..3.5)).sine.at(0.25)
    pitch = 4200.hz.transpose(base + ramp * slope + bump * arch + vibrato)
    amp = adsr(0.012, 0.03, 0.8, 0.04, hold: length, trigger: trigger)
    (pitch.sine + pitch.transpose(12).sine * 0.12) * amp
  end

  # A mouse along +x+, +y+, +z+: scratching ticks (dust through a
  # bandpass, as in textures round 3) in short bursts as it darts, and a
  # squeak now and then.  The ticks start above +dash+ m/s and reach 40 a
  # second (a little louder) 0.7 m/s faster; none while it walks slowly or
  # stands still (textures-6, 2026-10-16; the maintainer: "Tick density
  # should threshold so there's only brief moments of scratching as the
  # mouse darts").  The threshold is 1 m/s since textures-7 (the
  # maintainer, after 1.5: "A slightly lower threshold still would be
  # best, maybe 1m/s").  On the default path (seed 3, 32 s) the speed is
  # over 1 m/s 33% of the time, in 21 bursts (median 0.42 s, at most 2 s);
  # over 1.5 m/s 21%, in 16 bursts (median 0.4 s, at most 0.8 s);
  # textures-5's ticks followed any motion (71% of the time, bursts up to
  # 5 s).  Mono.
  def self.critter_mouse(x, y, z, dash: 1.0)
    vx, vy, vz = critter_velocity([x, y, z])
    speed = (vx * vx + vy * vy + vz * vz) ** 0.5
    darting = ((speed - dash) / 0.7).aclip(0, 1)
    steps = dust(darting * 40, range: 0.2..1, min_gap: 15.ms).filter(:bandpass, cutoff: 3500, quality: 1.5) * (darting * 0.3 + 0.7) * 0.8
    squeaks = critter_squeaks(dust(0.8, range: 0.5..1, min_gap: 600.ms)) * 0.05
    steps + squeaks
  end

  # Puts mono +sig+ at +x+, +y+, +z+ (nodes, meters) around you: delayed
  # by the distance (times +doppler+; 1 is real; +smooth+ Hz lowpasses
  # the delay time so darts swoop), darker and quieter with distance,
  # panned by x / r; or with +binaural+, each ear gets its own delay and
  # head shadow from Brown and Duda's spherical head model
  # (Woodworth's path around the head, a high shelf from 2x to 0.1x past
  # ~1.2 kHz by the ear's angle to the source) plus a gentle dulling above
  # 4 kHz behind you (the pinnae shade sound from behind; a rough cue
  # only).  Returns stereo.
  def self.critter_place(sig, x, y, z, doppler: 5, smooth: 1.5, binaural: false)
    # Paths that may pass behind cross the head; binaural keeps them 30 cm
    # off it (in quadrature), so levels stay sane
    r = binaural ? (x * x + y * y + z * z + 0.09) ** 0.5 : (x * x + y * y + z * z) ** 0.5
    late = r * (doppler / CRITTER_SOUND_SPEED)
    # The doppler follows the path through a +smooth+ Hz lowpass
    # (critically damped; nil or 0 off), so the darts and overshoots swoop
    # instead of warbling (textures-5; the maintainer: "Delay changes are a
    # little too extreme in speed").  Measured on the binaural fly (seed 5,
    # 32 s, 5x doppler) through the delay: unsmoothed, the pitch hit the
    # delay's own slew limit (-12 semitones) and changed at up to 144
    # semitones/s (95th percentile); 2 Hz keeps swoops to 4 semitones at
    # most, changing at up to 17 semitones/s (95th percentile).  The
    # default is 1.5 Hz (textures-6; the maintainer picked 1 Hz of 1, 2,
    # and 3, "1.3 to 1.6 might be perfect"): swoops at most 2.8 semitones
    # (1.0 at the 95th percentile), changing at up to 11 semitones/s (95th
    # percentile; 1.3 Hz: 2.4 and 9, 1.6 Hz: 3.1 and 12, 1 Hz: 1.6 and 6).
    late = late.filter(:lowpass, cutoff: smooth, quality: 0.5) if smooth && smooth > 0
    near = 1 / (r + 0.3)
    air = r * -1500 + 9000

    return (sig.delay(late, max_delay: 0.2).lp4(air) * near).pan(x / r) unless binaural

    head = CRITTER_HEAD / CRITTER_SOUND_SPEED
    behind = (y / r * -1).aclip(0, 1)
    sig = sig.filter(:highshelf, cutoff: 4000, gain: behind * -0.5 + 1, quality: 0.5)
    # Ear +side+ (-1 left, 1 right): u = cos of the angle from the ear's axis
    ears = [-1, 1].map { |side|
      u = x / r * side
      # Woodworth: -a/c cos(theta) facing the ear, a/c (theta - pi/2) around the head (plus a/c, so >= 0)
      path = u.aease(->(t) { c = 2 * t - 1; (c >= 0 ? 1 - c : 1 + Math.asin(-c)) / (1 + Math::PI / 2) }, in: -1..1, out: 0..(head * (1 + Math::PI / 2)))
      # Brown-Duda head shadow alpha(theta): 2 facing the ear, 0.1 at 150 degrees
      alpha = u.aease(->(t) { th = Math.acos((2 * t - 1).clamp(-1, 1)); (1.05 + 0.95 * Math.cos(th * 180 / 150) - 0.1) / 1.9 }, in: -1..1, out: 0.1..2.0)
      cutoff = 1248 / alpha ** 0.5
      sig.delay(late + path, max_delay: 0.2).lp4(air).filter(:highshelf, cutoff: cutoff, gain: alpha, quality: 0.5) * near
    }
    stereo(*ears) * 0.45 # -7 dB: closer paths and the lit ear's 2x shelf make binaural louder
  end

  # Plays the critters (:both, :fly, or :mouse) as players :fly and :mouse.
  def self.critters(which = :both, doppler: 5, smooth: 1.5, binaural: false)
    if which == :both || which == :fly
      x, y, z = critter_fly_path(behind: binaural)
      bg :fly, critter_place(critter_fly(x, y, z), x, y, z, doppler: doppler, smooth: smooth, binaural: binaural).at(8.db), fade: 0
    end
    if which == :both || which == :mouse
      x, y, z = critter_mouse_path(behind: binaural)
      bg :mouse, critter_place(critter_mouse(x, y, z), x, y, z, doppler: doppler, smooth: smooth, binaural: binaural).at(28.db), fade: 0 # dust ticks through a bandpass are quiet
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: 8,
      critter: [:both, 'which critters (both, fly, mouse)', '-c', Symbol],
      binaural: [false, 'headphones: per-ear delays and head shadow; critters may pass behind you'],
      doppler: [5.0, 'doppler exaggeration (1 is real)', '-D', Float, 0.0001..20],
      smooth: [1.5, 'doppler smoothing: a lowpass on the delay time in Hz (0 off: every dart warbles)', '-S', Float, 0.0..50],
      seed: [5, 'random seed (each seed is another flight)', '-s', Integer, 0..1_000_000],
    ) { |p|
      MB::Sound.seed(p.seed)
      bpm 60
      critters(p.critter, doppler: p.doppler, smooth: p.smooth, binaural: p.binaural)
    }
  end
end
