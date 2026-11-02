# Per-tick pitch tracking for tracker renders (tracker-2): the mean
# instantaneous frequency of the analytic signal (FFT Hilbert transform,
# bins above +cutoff+ dropped) over the middle 70% of each tick, where the
# level stays above 2% of the peak.  On a looped sine sample of a known
# number of frames this reads the playback rate to well under a cent per
# tick (calibrated against openmpt123 renders of synthetic modules; the
# measurement scripts are in the tracker-2 report).
module PitchTrack
  module_function

  # Frequencies (Hz) per tick of mono +x+ (an Array or Numo array) at
  # +rate+, for ticks of +tick_frames+ frames (a Rational or Float) from
  # frame 0: nil where the tick is quiet.
  def per_tick(x, tick_frames, ticks, rate: 48_000, cutoff: 5000.0)
    x = Numo::DFloat.cast(x)
    n = x.length
    spec = Numo::Pocketfft.fft(x.cast_to(Numo::DComplex))
    h = Numo::DFloat.zeros(n)
    top = [(cutoff * n / rate).round, n / 2].min
    h[0] = 1
    h[1...top] = 2
    z = Numo::Pocketfft.ifft(spec * h)
    d = z[1..] * z[0...-1].conj
    f = Numo::NMath.atan2(d.imag, d.real) * (rate / (2 * Math::PI))
    env = z.abs
    floor = env.max * 0.02
    Array.new(ticks) { |t|
      a = (t * tick_frames).round
      b = ((t + 1) * tick_frames).round
      m = ((b - a) * 0.15).round
      a += m
      b -= m
      next nil if b > f.length || b - a < 8 || env[a...b].min < floor
      f[a...b].mean
    }
  end

  # Cents from +a+ to +b+.
  def cents(a, b)
    1200 * Math.log2(b.to_f / a.to_f)
  end
end
