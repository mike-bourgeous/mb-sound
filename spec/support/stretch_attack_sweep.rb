# Stretch attack sweep (stretch-attacks-1, 2026-11-22): seeded synthetic
# loops whose attacks a spectral stretch must keep, checked at every attack
# the loop was built with, found by Sample::Onsets or not
# (spec/lib/mb/sound/sample_stretch_attack_sweep_spec.rb): the first 10 ms
# after each attack, at ratio times its time, may not fall
# more than LIMITS[kind] dB below the source's, for the looped default (the
# shape lock), looped `lock: :peaks`, and the unlooped stretch.
#
# Kinds (one per seed, in turn):
# - :note_change: a low note steps to another a few semitones away (two
#   bass partials under two bins apart in the vocoder's window; resets bin
#   by bin dipped such changes up to 15 dB)
# - :loop_cut: a loud bass to the loop's end, cut by a click whose most
#   lies in the last samples, into a quieter pluck (the loop point is the
#   attack; the frames of one pass never see the click)
# - :hits: noise hits over a ringing bass
#
#   FUZZ_SEED=1234 bundle exec rspec spec/lib/mb/sound/sample_stretch_attack_sweep_spec.rb
#   FUZZ=60 bundle exec rspec spec/lib/mb/sound/sample_stretch_attack_sweep_spec.rb   # the long mode
module StretchAttackSweep
  KINDS = %i[note_change loop_cut hits].freeze

  # The most an attack's first 10 ms may fall below the source's (dB),
  # per kind.  Measured on seeds 1000-1059: after stretch-attacks-1 the
  # worst note change -2.9 dB, loop cut -0.4, hits -3.6; before it -8.6,
  # -5.3, and -3.6 (the hits did not change).
  LIMITS = { note_change: 5.0, loop_cut: 2.0, hits: 5.0 }.freeze

  # Seeds that failed before their fix, checked in every run (a seed
  # draws another loop whenever the generator changes: then refind them
  # with FUZZ=60 on the code before the fix).
  FOUND = [1021, 1035, 1044].freeze

  # Cases known to fail for a reason recorded elsewhere, as
  # { seed => 'reason' }: skipped, counted.
  KNOWN = {}.freeze

  VARIANTS = {
    'looped default' => {},
    'looped lock: :peaks' => { lock: :peaks },
    'unlooped' => { wrap: false },
  }.freeze

  Case = Struct.new(:seed, :kind, :samples, :attacks, :ratio, keyword_init: true)

  module_function

  def build(seed)
    rng = Random.new(seed)
    kind = KINDS[seed % KINDS.length]
    ratio = [0.8, 0.9, 1.1, 1.2, 1.285, 1.4][rng.rand(6)] + rng.rand(-0.02..0.02)
    x, attacks = send(kind, rng)
    Case.new(seed: seed, kind: kind, samples: x, attacks: attacks, ratio: ratio.round(4))
  end

  def times(n) = Numo::DFloat.new(n).seq / 48000

  def note_change(rng)
    n = 48000 + rng.rand(48000)
    at = (n * rng.rand(0.35..0.65)).round
    f1 = 40.0 * 2**(rng.rand * 1.6)
    f2 = f1 * 2**((rng.rand(2..7) * (rng.rand < 0.5 ? -1 : 1)) / 12.0)
    t = times(n)
    f = Numo::DFloat.new(n).fill(f1)
    f[at..] = f2
    env = Numo::DFloat.new(n).fill(0.6)
    env[at..] = 0.6 + 0.4 * Numo::NMath.exp(-(t[at..] - t[at]) * 30)
    env[0...at] = 0.6 + 0.4 * Numo::NMath.exp(-t[0...at] * 30)
    [env * Numo::NMath.sin(t * f * (2 * Math::PI)) * 0.5, [at]]
  end

  def loop_cut(rng)
    # (a length leaving the last 40-60 samples out of every whole frame of
    # Sample::Onsets' 256-sample windows a 64-sample hop apart)
    n = 256 + 64 * rng.rand(500..1200) + 40 + rng.rand(20)
    t = times(n)
    x = Numo::NMath.sin(t * (2 * Math::PI * 40.0 * 2**(rng.rand * 1.2))) * (t / 0.2).clip(0, 1) * 0.5
    x += Numo::NMath.sin(t * (2 * Math::PI * rng.rand(150.0..400.0))) * Numo::NMath.exp(-t / 0.005) * 0.2
    k = Numo::DFloat.new(48).seq
    click = Numo::NMath.sin(k * (2 * Math::PI * rng.rand(2000.0..5000.0) / 48000.0)) * (0.5 - 0.5 * Numo::NMath.cos(k * (2 * Math::PI / 48))) * 0.4
    x[-36..] += click[0...36]
    x[0...12] += click[36..]
    [x, [0]]
  end

  def hits(rng)
    n = 48000 + rng.rand(48000)
    x = Numo::NMath.sin(times(n) * (2 * Math::PI * 40.0 * 2**(rng.rand * 1.2))) * 0.3
    at = Array.new(rng.rand(2..5)) { rng.rand(2000...(n - 4000)) }.sort
    at.each { |o| 800.times { |i| x[o + i] += (rng.rand * 2 - 1) * Math.exp(-i / 150.0) } }
    [x, at]
  end

  def rms(d) = Math.sqrt((d**2).mean)

  # The first 10 ms after +at+ (in a circle: a loop's output is one)
  def first10(d, at) = rms(d[(Numo::Int64.new(480).seq + at) % d.length])

  # [[variant, attack, dB re the source], ...] of every attack falling
  # more than LIMITS[kind] dB below the source's.
  def check(c)
    s = MB::Sound::Sample[Numo::SFloat.cast(c.samples)].looped
    x = Numo::DFloat.cast(s.data(0))
    bad = []
    VARIANTS.each do |name, kw|
      y = Numo::DFloat.cast(s.stretch(c.ratio, mode: :spectral, **kw).data(0))
      c.attacks.each do |o|
        src = first10(x, o)
        next if src < 1e-4

        db = 20 * Math.log10(first10(y, (o * c.ratio).round) / src)
        bad << [name, o, db.round(1)] if db < -LIMITS[c.kind]
      end
    end
    bad
  end

  def report(c, bad)
    "stretch attack sweep: seed #{c.seed} (FUZZ_SEED=#{c.seed}), #{c.kind} at #{c.ratio}x: " +
      bad.map { |name, o, db| "#{name}: the attack at #{o} #{db} dB" }.join('; ')
  end
end
