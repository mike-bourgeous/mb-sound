# Synthetic sounds with known answers for the sound-matching analysis
# specs (spec/lib/mb/sound/analysis/): tones with vibrato and AM of known
# rates and depths, seeded noise, a resonant bandpass sweep, a flanger, a
# kick with and without a click, a hat.  Plain Numo at 48 kHz, no graphs,
# so each answer comes from the formula, not from the library.
module SyntheticSounds
  RATE = 48_000

  module_function

  def times(seconds) = Numo::DFloat.new((seconds * RATE).round).seq / RATE

  # A tone of +harmonics+ partials (amplitude 1/k) at +hz+, scaled to
  # +level+ peak-ish, with optional vibrato (+vibrato: [rate Hz, ±cents]+)
  # and amplitude modulation (+am: [rate Hz, ±dB]+), and a 2 ms fade-in.
  def tone(hz, seconds, harmonics: 10, level: 0.3, vibrato: nil, am: nil)
    t = times(seconds)
    f = Numo::DFloat.new(t.length).fill(hz.to_f)
    f = f * 2**(vibrato[1] * Numo::NMath.sin(t * 2 * Math::PI * vibrato[0]) / 1200) if vibrato
    phase = f.cumsum / RATE
    y = Numo::DFloat.zeros(t.length)
    (1..harmonics).each { |k| y += Numo::NMath.sin(phase * 2 * Math::PI * k) / k }
    y *= 10**(am[1] * Numo::NMath.sin(t * 2 * Math::PI * am[0]) / 20) if am
    fade_in(y * level)
  end

  def sine(hz, seconds, level: 0.5) = fade_in(Numo::NMath.sin(times(seconds) * 2 * Math::PI * hz) * level)

  def fade_in(y, seconds = 0.002)
    n = [(seconds * RATE).round, y.length].min
    y[0...n] = y[0...n] * (Numo::DFloat.new(n).seq / n)
    y
  end

  # Uniform white noise in -1..1 from a seeded generator.
  def noise(seconds, seed: 1)
    rng = Random.new(seed)
    Numo::DFloat.cast(Array.new((seconds * RATE).round) { rng.rand * 2 - 1 })
  end

  # +x+ through an RBJ bandpass (constant 0 dB peak gain) whose center
  # follows +centers+ (Hz per sample), quality +q+.
  def bandpass(x, centers, q)
    y = Numo::DFloat.zeros(x.length)
    x1 = x2 = y1 = y2 = 0.0
    x.length.times do |i|
      w = 2 * Math::PI * centers[i] / RATE
      al = Math.sin(w) / (2 * q)
      a0 = 1 + al
      v = (al * x[i] - al * x2 + 2 * Math.cos(w) * y1 - (1 - al) * y2) / a0
      x2 = x1
      x1 = x[i]
      y2 = y1
      y1 = v
      y[i] = v
    end
    y
  end

  # Exponential sweep from +from+ to +to+ Hz over +n+ samples.
  def sweep(from, to, n) = from * (to.to_f / from)**(Numo::DFloat.new(n).seq / n)

  # +x+ plus itself delayed by +delays+ (seconds per sample, linear
  # interpolation): a flanger at full depth.
  def flanger(x, delays)
    y = x.dup
    x.length.times do |i|
      j = i - delays[i] * RATE
      k = j.floor
      next if k < 0
      fr = j - k
      y[i] += x[k] * (1 - fr) + (k + 1 < x.length ? x[k + 1] * fr : 0.0)
    end
    y
  end

  # A sine kick: 250 Hz falling to 60 Hz, 12/s decay, +seconds+ long; with
  # +click:+ a 3 ms burst of high noise on the first sample.
  def kick(seconds = 0.5, click: false)
    t = times(seconds)
    y = Numo::NMath.sin((t * 60 + (190 / 30.0) * (1 - Numo::NMath.exp(-t * 30))) * 2 * Math::PI) * Numo::NMath.exp(-t * 12) * 0.8
    y += hat(0.003, level: 0.3, seed: 7, decay: 300).concatenate(Numo::DFloat.zeros(t.length - 144)) if click
    y
  end

  # A hat: noise above 6 kHz decaying at +decay+ per second.
  def hat(seconds = 0.1, level: 0.5, seed: 3, decay: 60)
    n = noise(seconds, seed: seed)
    MB::Sound::Analysis::DSP.brickwall(n, RATE, nil, low: 6000.0) * Numo::NMath.exp(-times(seconds) * decay) * level
  end

  # +y+ with +x+ added at +seconds+ (cut to y's length).
  def add_at(y, x, seconds)
    out = y.dup
    a = (seconds * RATE).round
    n = [x.length, y.length - a].min
    out[a...(a + n)] += x[0...n]
    out
  end
end
