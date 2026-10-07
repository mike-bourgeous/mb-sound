RSpec.describe(MB::Sound::Curve) do
  let(:grid) { Numo::DFloat.linspace(0, 1, 4001) }

  # Every named curve plus parameterized and composed ones.
  def all_curves
    MB::Sound::Curve.names.map { |n| MB::Sound::Curve[n] } + [
      MB::Sound::Curve.db(-30), MB::Sound::Curve.db(12), MB::Sound::Curve.s(20), MB::Sound::Curve.s(-20),
      MB::Sound::Curve.power(0.5), MB::Sound::Curve.power(2.5),
      MB::Sound::Curve[:elastic, overshoot: 0.5, cycles: 5], MB::Sound::Curve[:squiggle, overshoot: 0.3, cycles: 7],
      MB::Sound::Curve[:bounce, overshoot: 0.5, cycles: 5], MB::Sound::Curve.steps(5, :sine),
      MB::Sound::Curve.bezier(0.3, -0.4, 0.7, 1.4),
      MB::Sound::Curve[:elastic].reverse, MB::Sound::Curve[:bounce_in_out], MB::Sound::Curve[:back_out_in],
      MB::Sound::Curve[:sine] >> :steps, MB::Sound::Curve[:linear].blend(:bounce, 0.3),
      MB::Sound::Curve.new { |x| x * x * x },
    ]
  end

  it 'starts at 0 and ends at 1 for every curve' do
    all_curves.each do |c|
      expect(c.(0)).to be_within(1e-12).of(0), c.to_s
      expect(c.(1)).to be_within(1e-12).of(1), c.to_s
    end
  end

  it 'gives the same values from #map (vectorized) and #call (scalar)' do
    x = Numo::DFloat.linspace(-0.3, 1.3, 1601)
    all_curves.each do |c|
      v = c.map(x)
      s = Numo::DFloat.cast(x.to_a.map { |e| c.(e) })
      expect((v - s).abs.max).to eq(0), c.to_s
    end
  end

  it 'never goes down where promised' do
    monotonic = all_curves.select(&:monotonic?)
    expect(monotonic.map(&:to_s)).to include('smoothstep', 'sine', 'db(-30.0)', 's(20.0)', 'steps(4)', 'bezier(0.25, 0.1, 0.25, 1.0)')
    monotonic.each do |c|
      d = c.map(grid).diff
      expect(d.min).to be >= -1e-12, c.to_s
    end
  end

  it 'stays within 0..1 for monotonic curves and the bounce' do
    (all_curves.select(&:monotonic?) + [MB::Sound::Curve[:bounce, overshoot: 0.6, cycles: 6]]).each do |c|
      lo, hi = c.extent(4001)
      expect(lo).to be >= -1e-12, c.to_s
      expect(hi).to be <= 1 + 1e-12, c.to_s
    end
  end

  describe 'overshoot' do
    it 'passes the target by the overshoot for back and elastic' do
      [0.02, 0.1, 0.4].each do |o|
        expect(MB::Sound::Curve.back(overshoot: o).extent(4001)[1]).to be_within(2e-4).of(1 + o)
        expect(MB::Sound::Curve.elastic(overshoot: o, cycles: 3).extent(4001)[1]).to be_within(2e-4).of(1 + o)
      end
    end

    it 'anticipates by the overshoot for anticipate (back reversed)' do
      expect(MB::Sound::Curve[:anticipate, overshoot: 0.2].extent(4001)[0]).to be_within(2e-4).of(-0.2)
    end

    it 'passes the target by exactly the overshoot for squiggles, with later wiggles' do
      [0.05, 0.2, 0.4].each do |o|
        c = MB::Sound::Curve.squiggle(overshoot: o, cycles: 4)
        lo, hi = c.extent(4001)
        expect(hi).to be_within(1e-4).of(1 + o)
        expect(lo).to be >= -o
        # the swing after the peak is about as large (slow decay)
        late = c.map(Numo::DFloat.linspace(0.75, 0.9, 301))
        expect(late.max - 1).to be > o * 0.7
      end
      expect(MB::Sound::Curve[:squiggle].options).to eq(overshoot: 0.2, cycles: 4.0)
    end

    it 'bounces back by the overshoot (first bounce height)' do
      c = MB::Sound::Curve.bounce(overshoot: 0.25, cycles: 3)
      y = c.map(grid)
      t0 = 1 / 2.75
      after = y[grid.ge(t0 + 1e-9)]
      expect(1 - after.min).to be_within(1e-6).of(0.25)
    end

    it 'matches Robert Penner\'s easeOutBounce with the defaults' do
      penner = ->(x) {
        if x < 1 / 2.75 then 7.5625 * x * x
        elsif x < 2 / 2.75 then x -= 1.5 / 2.75; 7.5625 * x * x + 0.75
        elsif x < 2.5 / 2.75 then x -= 2.25 / 2.75; 7.5625 * x * x + 0.9375
        else x -= 2.625 / 2.75; 7.5625 * x * x + 0.984375
        end
      }
      grid.to_a.each { |x| expect(MB::Sound::Curve[:bounce].(x)).to be_within(1e-12).of(penner.(x)) }
    end

    it 'settles with zero slope at the end for back, elastic, and squiggle' do
      [MB::Sound::Curve[:back], MB::Sound::Curve[:elastic], MB::Sound::Curve[:squiggle]].each do |c|
        expect(c.slopes[1].abs).to be < 1e-4, c.to_s
      end
    end

    it 'rejects overshoots an elastic curve cannot reach' do
      expect { MB::Sound::Curve.elastic(overshoot: 0.9, cycles: 1) }.to raise_error(ArgumentError, /below/)
    end
  end

  describe 'Envelope and Glide equivalents' do
    it 'uses the same dB scale as Envelope' do
      expect(MB::Sound::Curve::DB_SCALE).to eq(MB::Sound::Envelope::CURVE_SCALE)
      expect(MB::Sound::Curve::LINEAR_LIMIT).to eq(MB::Sound::Envelope::LINEAR_LIMIT)
    end

    it 'matches a linear-timed Envelope attack with a dB curve' do
      [-24, 0, 30].each do |d|
        env = MB::Sound::Envelope.new(attack: 0.01, decay: 0.1, sustain: 1, release: 0.1, curve: [d, 0, 0], hold: false, sample_rate: 48000)
        out = env.sample(480)
        c = MB::Sound::Curve.db(d)
        x = Numo::DFloat.new(480).seq / 480.0
        expect((out - c.map(x)).abs.max).to be < 1e-6, "#{d} dB"
      end
    end

    it 'matches an Envelope :s attack with Curve.s' do
      [-20, 0, 20].each do |d|
        env = MB::Sound::Envelope.new(attack: 0.01, decay: 0.1, sustain: 1, release: 0.1, curve: [d, 0, 0], shape: :s, hold: false, sample_rate: 48000)
        out = env.sample(480)
        x = Numo::DFloat.new(480).seq / 480.0
        expect((out - MB::Sound::Curve.s(d).map(x)).abs.max).to be < 1e-6, "#{d} dB"
      end
    end

    it 'reverses a dB curve into the opposite dB curve' do
      expect((MB::Sound::Curve.db(30).reverse.map(grid) - MB::Sound::Curve.db(-30).map(grid)).abs.max).to be < 1e-12
    end

    it 'gives Glide its overshoot bump scale' do
      expect(MB::Sound::Notes::Glide.overshoot_k(0.1)).to eq(MB::Sound::Curve.back_k(0.1))
      g = ->(t, k) { t * t * (3 - 2 * t) + k * t**3 * (1 - t)**2 }
      k = MB::Sound::Curve.back_k(0.1)
      grid.to_a.each { |t| expect(MB::Sound::Curve.back(overshoot: 0.1).(t)).to be_within(1e-14).of(g.(t, k)) }
    end
  end

  describe 'composition' do
    it 'reverses: 1 - f(1 - x)' do
      c = MB::Sound::Curve[:bounce]
      expect(c.reverse.(0.3)).to be_within(1e-15).of(1 - c.(0.7))
      expect(c.reverse.kind).to eq(:in)
    end

    it 'derives in and out forms from in-out curves and back' do
      expect((MB::Sound::Curve[:sine].in.map(grid) - MB::Sound::Curve.sine_in.map(grid)).abs.max).to be < 1e-12
      expect((MB::Sound::Curve[:sine].out.map(grid) - MB::Sound::Curve.sine_out.map(grid)).abs.max).to be < 1e-12
      expect((MB::Sound::Curve.sine_in.in_out.map(grid) - MB::Sound::Curve.sine.map(grid)).abs.max).to be < 1e-12
    end

    it 'parses _in, _out, _in_out, and _out_in suffixes' do
      expect(MB::Sound::Curve[:elastic_in].kind).to eq(:in)
      expect(MB::Sound::Curve[:elastic_out]).to eq(MB::Sound::Curve[:elastic])
      expect(MB::Sound::Curve[:quad_in_out].(0.5)).to be_within(1e-15).of(0.5)
      expect(MB::Sound::Curve[:bounce_out_in].(0.25)).to be_within(1e-15).of(MB::Sound::Curve[:bounce].(0.5) / 2)
    end

    it 'chains curves with >>' do
      c = MB::Sound::Curve[:sine] >> MB::Sound::Curve.steps(4)
      expect(c.(0.5)).to eq(0.5)
      expect(c.(0.1)).to eq(0.25)
    end

    it 'makes staircases that hold the target for the last step' do
      s = MB::Sound::Curve.steps(4)
      expect([0, 0.01, 0.25, 0.26, 0.5, 0.74, 0.76, 1].map { |x| s.(x) }).to eq([0, 0.25, 0.25, 0.5, 0.5, 0.75, 1, 1])
    end
  end

  describe '.from' do
    it 'converts names, numbers (dB), Procs, arrays (bezier), and curves' do
      expect(MB::Sound::Curve.from(:smooth)).to eq(MB::Sound::Curve.smoothstep)
      expect(MB::Sound::Curve.from(30).to_s).to eq('db(30.0)')
      expect(MB::Sound::Curve.from(->(x) { x * x }).(0.5)).to eq(0.25)
      expect(MB::Sound::Curve.from([0.42, 0, 0.58, 1])).to eq(MB::Sound::Curve[:ease_in_out])
      expect(MB::Sound::Curve.from(nil)).to be_nil
    end

    it 'passes options to named curves and rejects unknown options and names' do
      expect(MB::Sound::Curve[:elastic, overshoot: 0.2, cycles: 4].options).to eq(overshoot: 0.2, cycles: 4.0)
      expect { MB::Sound::Curve[:sine, overshoot: 0.2] }.to raise_error(ArgumentError, /no options/)
      expect { MB::Sound::Curve[:steps, overshoot: 0.2] }.to raise_error(ArgumentError, /cycles/)
      expect { MB::Sound::Curve[:wobble] }.to raise_error(ArgumentError, /Unknown curve/)
    end
  end

  describe 'bezier' do
    it 'solves x(t) accurately' do
      c = MB::Sound::Curve.bezier(0.25, 0.1, 0.25, 1)
      t = Numo::DFloat.linspace(0, 1, 101)
      bx = 3 * (1 - t)**2 * t * 0.25 + 3 * (1 - t) * t**2 * 0.25 + t**3
      by = 3 * (1 - t)**2 * t * 0.1 + 3 * (1 - t) * t**2 * 1 + t**3
      expect((c.map(bx) - by).abs.max).to be < 1e-9
    end
  end

  describe '#map_edges' do
    let(:x) { Numo::DFloat[-0.5, 0, 0.25, 1, 1.25, 1.75, 2.5] }

    it 'clamps by default' do
      y = MB::Sound::Curve[:sine_in].map_edges(x)
      expect(y[0]).to eq(0)
      expect(y[4]).to be_within(1e-15).of(1)
    end

    it 'wraps and mirrors' do
      c = MB::Sound::Curve.linear
      expect(c.map_edges(x, :wrap).to_a).to eq([0.5, 0, 0.25, 0, 0.25, 0.75, 0.5])
      expect(c.map_edges(x, :mirror).to_a).to eq([0.5, 0, 0.25, 1, 0.75, 0.25, 0.5])
    end

    it 'extends natural curves with their formula and others with their end slopes' do
      expect(MB::Sound::Curve.sine.map_edges(Numo::DFloat[2.0], :extend)[0]).to be_within(1e-12).of(0)
      y = MB::Sound::Curve[:quad].map_edges(Numo::DFloat[-1.0, 2.0], :extend)
      expect(y[0]).to be_within(1e-5).of(0)
      expect(y[1]).to be_within(1e-5).of(3)
    end

    it 'gives the raw formula with :none' do
      expect(MB::Sound::Curve[:quad].map_edges(Numo::DFloat[2.0], :none)[0]).to eq(4)
    end
  end
end

RSpec.describe('MB::Sound::Curve#lookup') do
  let(:x) { Numo::DFloat.linspace(0, 1, 20001) }

  def curves
    MB::Sound::Curve.names.map { |n| MB::Sound::Curve[n] } + [
      MB::Sound::Curve.steps(7), MB::Sound::Curve.steps(3, :sine), MB::Sound::Curve[:elastic, overshoot: 0.6, cycles: 8],
      MB::Sound::Curve[:squiggle, cycles: 9, overshoot: 0.4], MB::Sound::Curve[:bounce, cycles: 8, overshoot: 0.7],
      MB::Sound::Curve[:elastic].reverse, MB::Sound::Curve.new { |v| v**0.5 },
    ]
  end

  it 'matches #map closely (exactly for staircases), clamping outside 0..1' do
    curves.each do |c|
      err = (c.lookup(x.dup) - c.map(x)).abs.max
      limit = case c.to_s
              when /bounce/ then 5e-4 # kinks inside cells
              when /bezier\(0.42, 0.0, 1.0|bezier\(0.0, 0.0/ then 2e-3 # vertical end slopes
              when /custom/ then 0.025 # sqrt: an infinite slope, wrong in the first cell (1/2048)
              when /steps/ then 1e-15
              else 1e-7
              end
      expect(err).to be <= limit, "#{c}: #{err}"
    end
    expect(MB::Sound::Curve[:elastic].lookup(Numo::DFloat[-1, 2]).to_a).to eq([0, 1])
  end

  it 'gives the same values as its Ruby mirror' do
    curves.each do |c|
      t = c.value_table
      r = Numo::DFloat.cast(x.to_a.each_slice(97).map(&:first).map { |v| MB::Sound::Curve.lookup_ruby(t, v) })
      expect(c.lookup(Numo::DFloat.cast(x.to_a.each_slice(97).map(&:first)))).to eq(r), c.to_s
    end
  end

  it 'modifies a contiguous DFloat in place' do
    t = Numo::DFloat[0, 0.5, 1]
    expect(MB::Sound::Curve[:quad].lookup(t)).to equal(t)
    expect(t[1]).to be_within(1e-9).of(0.25)
  end

  it 'rejects bad tables' do
    expect { MB::Sound::FastClip.curve_lookup(Numo::SFloat[0], *MB::Sound::Curve[:quad].value_table) }.to raise_error(ArgumentError, /DFloat/)
    expect { MB::Sound::FastClip.curve_lookup(Numo::DFloat[0], nil, nil, nil, nil) }.to raise_error(ArgumentError, /table/)
    expect { MB::Sound::FastClip.curve_lookup(Numo::DFloat[0], Numo::DFloat[0, 1], Numo::DFloat[0], Numo::DFloat[0, 1], Numo::DFloat[0, 1]) }.to raise_error(ArgumentError, /short/)
  end
end
