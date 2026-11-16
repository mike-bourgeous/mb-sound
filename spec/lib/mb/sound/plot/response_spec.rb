require_relative '../../../../support/allocation_budget'

RSpec.describe(MB::Sound::Plot::Response, :aggregate_failures) do
  let(:resp) { MB::Sound::Plot::Response }

  # Transfer functions the displays draw: four-poles in every mode, a
  # biquad, a flat gain, an all-zero numerator (the floor), and 0/0.
  def cases
    b = Array.new(5, 0.0)
    a = Array.new(5, 0.0)
    fp = %i[lp4 hp4 bp2 diode].map { |m|
      MB::Sound::Filter::FourPole.new(cutoff: 900, resonance: 0.7, mode: m, sample_rate: 48000).z_polynomials(b, a)
      [b.dup, a.dup]
    }
    fp + [[[0.2, 0.4, 0.2], [1.0, -0.6, 0.3]], [[2.0], [1.0]], [[0.0, 0.0], [1.0, 0.5]], [[0.0], [0.0]]]
  end

  it 'gives what its Ruby mirror gives within 1e-4 dB, at least the floor' do
    cases.each do |b, a|
      [[256, 20.0, 23976.0, -60.0], [7, 100.0, 1000.0, -120.0], [1, 440.0, 440.0, -30.0]].each do |n, lo, hi, floor|
        c = Numo::SFloat.new(n)
        r = Numo::SFloat.new(n)
        expect(MB::Sound::FastUI.response_db(c, b, a, 48000.0, lo, hi, floor)).to equal(c)
        expect(resp.db_ruby(r, b, a, 48000.0, lo, hi, floor)).to equal(r)
        expect((c - r).abs.max).to be <= 1e-4, "#{b} / #{a} at #{n} points"
        expect(c.min).to be >= floor - 1e-4
      end
    end
    out = Numo::SFloat.new(3)
    MB::Sound::FastUI.response_db(out, [0.0], [0.0], 48000.0, 20.0, 2000.0, -60.0)
    expect(out.to_a).to all(be_within(1e-4).of(-60.0)) # (0/0 reads the floor)
  end

  it 'matches Presets.response_db of the filter itself' do
    f = MB::Sound::Filter::FourPole.new(cutoff: 2000, resonance: 0.6, sample_rate: 48000)
    b = Array.new(5, 0.0)
    a = Array.new(5, 0.0)
    f.z_polynomials(b, a)
    out = resp.db(Numo::SFloat.new(256), b, a, 48000, 20, 23976, -60.0)
    _, db = MB::Sound::Plot::Presets.response_db(f, 48000)
    expect((out - Numo::SFloat.cast(db.clip(-60.0, nil))).abs.max).to be < 1e-3
  end

  it 'raises for bad arguments in C and Ruby alike' do
    out = Numo::SFloat.new(4)
    [
      [Numo::DFloat.new(4), [1.0], [1.0], 48000.0, 20.0, 200.0, -60.0],
      [out, [], [1.0], 48000.0, 20.0, 200.0, -60.0],
      [out, [1.0], Array.new(17, 1.0), 48000.0, 20.0, 200.0, -60.0],
      [out, [1.0], [1.0], 0.0, 20.0, 200.0, -60.0],
      [out, [1.0], [1.0], 48000.0, -1.0, 200.0, -60.0],
      [out, [1.0], [1.0], 48000.0, 20.0, 200.0, Float::NAN],
    ].each do |args|
      expect { MB::Sound::FastUI.response_db(*args) }.to raise_error(ArgumentError)
      expect { resp.db_ruby(*args) }.to raise_error(ArgumentError)
    end
    expect { MB::Sound::FastUI.response_db(out, 1.0, [1.0], 48000.0, 20.0, 200.0, -60.0) }.to raise_error(TypeError)
    expect { MB::Sound::FastUI.response_db(Numo::SFloat.new(2).freeze, [1.0], [1.0], 48000.0, 20.0, 200.0, -60.0) }.to raise_error(FrozenError)
  end

  it 'allocates nothing' do
    b, a = cases.first
    out = Numo::SFloat.new(256)
    m = AllocationBudget.measure(buffers: 100) { MB::Sound::FastUI.response_db(out, b, a, 48000.0, 20.0, 23976.0, -60.0) }
    expect(m.objects_per_buffer).to be <= 0.2, m.report
  end

  it 'draws SVF and cookbook filters of every type from their z_polynomials as their #response gives' do
    w = Numo::DFloat.logspace(Math.log10(20.0), Math.log10(23976.0), 64) * (2 * Math::PI / 48000)
    b = Array.new(5, 1.0)
    a = Array.new(5, 1.0)
    rng = Random.new(9)
    filters = MB::Sound::Filter::SVF::FILTER_TYPES.map { |t|
      first = MB::Sound::Filter::SVF::FIRST_ORDER_TYPES.include?(t)
      MB::Sound::Filter::SVF.new(t, 48000, 20 * 2**(rng.rand * 10), quality: first ? nil : 0.3 + rng.rand * 8, gain: 0.25 + rng.rand * 3)
    } + %i[lowpass highpass bandpass notch allpass peak lowshelf highshelf].map { |t|
      MB::Sound::Filter::Cookbook.new(t, 48000, 20 * 2**(rng.rand * 10), quality: 0.3 + rng.rand * 8, db_gain: rng.rand * 24 - 12)
    }
    filters.each do |f|
      expect(f.z_polynomials(b, a)).to equal(b)
      expect(b[3..] + a[3..]).to eq([0.0] * 4) # (further entries zeroed)
      out = resp.db_ruby(Numo::SFloat.new(64), b, a, 48000, 20.0, 23976.0, -60.0)
      ref = Numo::SFloat.cast((20 * Numo::NMath.log10(Numo::DComplex.cast(f.response(w)).abs)).clip(-60.0, nil))
      expect((out - ref).abs.max).to be < 1e-3, f.to_s
    end
    f = MB::Sound::Filter::SVF.new(:peak, 48000, 800, quality: 2.0, gain: 2.0)
    f.z_polynomials(b, a)
    before = GC.stat(:total_allocated_objects)
    100.times { |i| f.cutoff = 300.0 + i; f.z_polynomials(b, a) }
    expect(GC.stat(:total_allocated_objects) - before).to be <= 2
  end
end

