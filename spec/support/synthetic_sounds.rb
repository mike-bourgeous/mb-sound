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

  # A stereo impulse response of exponentially decaying noise: +t60s+ maps
  # octave band centers (Hz) to their T60 in seconds (each band's noise
  # spans center / 1.38 to center * 1.38, so bands never share FFT bins),
  # after +predelay+ seconds of silence, with +tilt_db+ dB per octave around
  # 1 kHz, a +correlation+ between the channels, and white noise at
  # +floor+ (peak-relative amplitude) under everything.
  def impulse_response(t60s, seconds: 1.5, predelay: 0.0, seed: 1, tilt_db: 0.0, correlation: 0.0, floor: 0.0)
    rng = Random.new(seed)
    n = (seconds * RATE).round
    t = Numo::DFloat.new(n).seq / RATE
    noise = -> { Numo::DFloat[*Array.new(n) { rng.rand - 0.5 }] }
    m = 2**Math.log2(n).ceil * 2
    f = Numo::DFloat.new(m / 2 + 1).seq * (RATE.to_f / m)
    band = lambda { |x, center|
      xx = Numo::DFloat.zeros(m)
      xx[0...n] = x
      spec = Numo::Pocketfft.rfft(xx)
      spec[(f < center / 1.38) | (f > center * 1.38)] = 0
      Numo::Pocketfft.irfft(spec)[0...n].dup
    }
    chans = [Numo::DFloat.zeros(n), Numo::DFloat.zeros(n)]
    t60s.each do |center, t60|
      env = Numo::NMath.exp(-Math.log(1000) * t / t60) * 10**(tilt_db * Math.log2(center / 1000.0) / 20)
      common = band.(noise.(), center)
      chans.each do |c|
        c.inplace + (band.(noise.(), center) * Math.sqrt(1 - correlation) + common * Math.sqrt(correlation)) * env
      end
    end
    peak = chans.map { |c| c.abs.max }.max
    pre = (predelay * RATE).round
    chans.map { |c|
      c = c / peak
      c += noise.() * (2 * floor) if floor > 0
      Numo::DFloat.zeros(pre).concatenate(c)
    }
  end
end
