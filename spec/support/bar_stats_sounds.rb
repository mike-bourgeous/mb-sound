# Synthetic songs with known answers for the bar statistics specs
# (spec/lib/mb/sound/bar_stats/): per beat a kick (55 Hz, the low band), a
# chord (the mid band; stereo by default), and a hat (noise high-passed
# into the high band), at a known tempo from a known first downbeat, with
# one thing changed where a spec asks: a band delayed by N samples, a gain
# step, a stereo collapse, a missing band, a transpose, a reverb-like tail.
# Plain Numo at 48 kHz, no graphs, so each answer comes from the recipe.
module BarStatsSounds
  RATE = 48_000

  # The first downbeat (seconds).
  OFFSET = 0.25

  # Chord notes (Hz): C major (C4 E4 G4).
  CHORD = [261.6256, 329.6276, 391.9954].freeze

  module_function

  # [left, right] DFloats of +bars+ 4/4 bars at +bpm+ plus a second of
  # silence, the first downbeat at OFFSET.
  #
  # +delay+: samples each band's hits are late ({ high: 96 }).
  # +gain+: a lambda of the bar number giving a linear gain.
  # +mono+: bar numbers whose chord is the same on both sides (else the
  #         right channel's chord is a quarter cycle off).
  # +drop+: bands left out ({ low: 3..4 } leaves the kick out of bars 3-4).
  # +transpose+: { bars => semitones } for the chord.
  # +tail+: a decaying noise tail after each hit (a reverb's), 300 ms.
  # +shift+: samples of silence put before everything (a file offset).
  def song(bpm: 120, bars: 8, delay: {}, gain: nil, mono: [], drop: {}, transpose: {}, tail: false, shift: 0, seed: 1)
    spb = 60.0 / bpm
    n = ((OFFSET + bars * 4 * spb + 1) * RATE).round + shift
    l = Numo::DFloat.zeros(n)
    r = Numo::DFloat.zeros(n)
    rng = Random.new(seed)
    hat = hat_burst(rng)
    tail_noise = tail ? noise_tail(rng) : nil
    (bars * 4).times do |k|
      bar = k / 4 + 1
      g = gain ? gain.(bar) : 1.0
      s = ((OFFSET + k * spb) * RATE).round + shift
      unless drop[:low]&.include?(bar)
        add(l, r, kick, s + delay.fetch(:low, 0), g)
      end
      unless drop[:mid]&.include?(bar)
        semis = transpose.find { |range, _| range.include?(bar) }&.last || 0
        cl, cr = chord(spb * 0.9, semis, mono.include?(bar))
        o = s + delay.fetch(:mid, 0)
        add(l, nil, cl, o, g)
        add(r, nil, cr, o, g)
      end
      unless drop[:high]&.include?(bar)
        add(l, r, hat, s + delay.fetch(:high, 0), g)
      end
      add(l, r, tail_noise, s + (0.02 * RATE).round, g) if tail_noise
    end
    [l, r]
  end

  # Adds +x+ times +g+ into +l+ (and +r+) from sample +s+.
  def add(l, r, x, s, g)
    e = [s + x.length, l.length].min
    return if e <= s
    l[s...e] += x[0...(e - s)] * g
    r[s...e] += x[0...(e - s)] * g if r
  end

  def times(seconds) = Numo::DFloat.new((seconds * RATE).round).seq / RATE

  # A 55 Hz kick decaying over about 150 ms.
  def kick
    t = times(0.2)
    Numo::NMath.sin(t * (2 * Math::PI * 55)) * Numo::NMath.exp(-t * 20) * 0.5
  end

  # The chord for +seconds+ (+semis+ up), left and right (a quarter cycle
  # apart on the right unless +mono+), with 5 ms fades.
  def chord(seconds, semis = 0, mono = false)
    t = times(seconds)
    l = Numo::DFloat.zeros(t.length)
    r = Numo::DFloat.zeros(t.length)
    CHORD.each do |f|
      f *= 2**(semis / 12.0)
      l += Numo::NMath.sin(t * (2 * Math::PI * f)) * 0.08
      r += Numo::NMath.sin(t * (2 * Math::PI * f) + (mono ? 0 : Math::PI / 2)) * 0.08
    end
    fade = [(0.005 * RATE).round, t.length / 2].min
    ramp = Numo::DFloat.new(fade).seq / fade
    [l, r].each { |c| c[0...fade] *= ramp; c[-fade..] *= ramp.reverse }
    [l, r]
  end

  # A 30 ms noise burst in the high band (the library's band split, so it
  # stays out of the others).
  def hat_burst(rng)
    x = Numo::DFloat.cast(Array.new((0.03 * RATE).round) { rng.rand * 2 - 1 }) * Numo::NMath.exp(-times(0.03) * 150) * 0.3
    MB::Sound::BarStats::Bands.split(x, RATE)[2]
  end

  # 300 ms of decaying noise (a reverb tail), mid and high.
  def noise_tail(rng)
    x = Numo::DFloat.cast(Array.new((0.3 * RATE).round) { rng.rand * 2 - 1 }) * Numo::NMath.exp(-times(0.3) * 8) * 0.05
    MB::Sound::BarStats::Bands.split(x, RATE).drop(1).sum
  end
end
