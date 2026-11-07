RSpec.describe(MB::Sound::GraphNode::DbShaper) do
  include BufferSizeHelpers

  DBS = MB::Sound::GraphNode::DbShaper unless defined?(DBS)

  # The formula, written out from the points (plain dB numbers, [in, out]
  # pairs): y = sign(x) 10^(T(20 log10 |x|) / 20), T straight lines between
  # the points, continued past both ends (below: :unity uses slope 1 under
  # the first point, :silence gives 0 there), then mixed with x.  Two
  # points at one input are a step to the second one's output.
  def reference(x, points, negative = nil, below: :line, above: :line, mix: 1.0)
    return 0.0 if x == 0

    pts = (x < 0 && negative ? negative : points).map { |p| p.map(&:to_f) }.each_with_index.sort_by { |p, i| [p[0], i] }.map(&:first)
    lines = pts.each_cons(2).reject { |a, b| a[0] == b[0] }
    l = 20 * Math.log10(x.abs)
    db =
      if l < pts[0][0]
        a, b = lines.first
        case below
        when :silence then nil
        when :unity then a[1] + (l - a[0])
        else a[1] + (b[1] - a[1]) / (b[0] - a[0]) * (l - a[0])
        end
      elsif above == :unity && l >= pts[-1][0]
        pts[-1][1] + (l - pts[-1][0])
      else
        a, b = lines.reverse.find { |p, _| p[0] <= l }
        a[1] + (b[1] - a[1]) / (b[0] - a[0]) * (l - a[0])
      end
    y = db.nil? ? 0.0 : (x < 0 ? -1 : 1) * 10**(db / 20.0)
    x + mix * (y - x)
  end

  # Levels from -110 dB to +12 dB of both signs, and zero.
  let(:levels) {
    db = (-110..12).step(0.37).to_a
    Numo::SFloat.cast([0.0] + db.map { |d| 10**(d / 20.0) } + db.map { |d| -10**(d / 20.0) })
  }

  def input(data) = MB::Sound::ArrayInput.new(data: [data])

  # Non-harmonic power below 20 kHz relative to harmonic power (dB), with
  # coherent sampling at bin +k+ (as in shaper_spec).
  def alias_db(node, k, n: 16384)
    node.sample(4800)
    data = Numo::DFloat.cast(node.sample(n))
    pow = MB::Sound.real_fft(data).abs**2
    harm = Numo::Bit.zeros(pow.length)
    (k...pow.length).step(k) { |b| harm[b] = 1 }
    other = ~harm
    other[0] = 0
    other[(20000.0 / 48000 * n).ceil..] = 0
    10 * Math.log10(pow[other.where].sum / pow[harm.where].sum)
  end

  def db_points(pts) = pts.map { |i, o| [i.db, o.db] }

  DB_SHAPER_CURVES = {
    'a soft knee' => [[[-84, -84], [-24, -24], [-12, -14], [0, -9]], nil],
    'a fold-back' => [[[-84, -84], [-12, -6], [0, -24]], nil],
    'a gate-like low end' => [[[-84, -120], [-40, -100], [-30, -30], [0, 0]], nil],
    'separate halves' => [[[-84, -84], [-20, -20], [0, -6]], [[-84, -84], [-30, -30], [-12, -14], [0, -14]]],
    'steps up and down' => [[[-84, -84], [-34, -40], [-34, -12], [-10, -8], [-10, -20], [0, -14]], [[-84, -84], [-20, -30], [-20, -10], [0, -6]]],
  }.freeze

  describe 'the exact version (#ashape_db)' do
    DB_SHAPER_CURVES.each do |name, (points, negative)|
      %i[line unity silence].each do |below|
        [1.0, 0.4].each do |mix|
          it "follows the formula for #{name} (below #{below}, mix #{mix}) within float32 rounding" do
            node = input(levels).ashape_db(db_points(points), negative: negative && db_points(negative), below: below, mix: mix)
            out = node.sample(levels.length)
            ref = levels.to_a.map { |x| reference(x, points, negative, below: below, mix: mix) }
            ref.each_with_index do |r, i|
              expect(out[i]).to be_within(2e-7 * [r.abs, 1e-30].max + 1e-38).of(r), "x = #{levels[i]}"
            end
          end
        end
      end
    end

    DB_SHAPER_CURVES.each do |name, (points, negative)|
      it "follows the formula for #{name} with above: :unity (slope 1 over the last point)" do
        node = input(levels).ashape_db(db_points(points), negative: negative && db_points(negative), below: :unity, above: :unity)
        out = node.sample(levels.length)
        levels.to_a.each_with_index do |x, i|
          r = reference(x, points, negative, below: :unity, above: :unity)
          expect(out[i]).to be_within(2e-7 * [r.abs, 1e-30].max + 1e-38).of(r), "x = #{x}"
        end
      end
    end

    it 'follows a cubic curve (Dynamics::Transfer.points with :cubic)' do
      pts = [[-60, -40], [-20, -10], [0, -3]]
      t = MB::Sound::GraphNode::Dynamics::Transfer.points(pts, interpolation: :cubic)
      out = input(levels).ashape_db(db_points(pts), interpolation: :cubic).sample(levels.length)
      levels.to_a.each_with_index do |x, i|
        next if x == 0
        r = (x < 0 ? -1 : 1) * 10**(t.call(20 * Math.log10(x.abs)) / 20.0)
        expect(out[i]).to be_within(2e-7 * r.abs).of(r)
      end
    end

    it 'keeps zero at zero and keeps the sign' do
      out = input(Numo::SFloat[0, 0.5, -0.5]).ashape_db(:fuzz).sample(3)
      expect(out[0]).to eq(0)
      expect(out[1]).to be > 0
      expect(out[2]).to eq(-out[1])
    end

    it 'matches its Ruby mirror sample for sample' do
      DB_SHAPER_CURVES.each do |name, (points, negative)|
        %i[line silence].each do |below|
          node = input(levels).ashape_db(db_points(points), negative: negative && db_points(negative), below: below, mix: 0.7)
          c = node.sample(levels.length)
          r = DBS.shape_db_ruby(levels.dup, node.instance_variable_get(:@pos_table), node.instance_variable_get(:@neg_table), 0.7,
                                node.instance_variable_get(:@pos_floor), node.instance_variable_get(:@neg_floor))
          expect(c).to eq(r), name
        end
      end
    end
  end

  describe 'the antialiased version (#shape_db)' do
    # A test signal crossing every level, jumping, and repeating samples
    # (the kernel's midpoint branch)
    def signal(n = 1200)
      x = Numo::DFloat.new(n).seq
      s = Numo::NMath.sin(x * 0.07) * 1.6 + (x / n - 0.5) * 0.8
      s[100..110] = 0.25
      s[500] = 3.0
      s[600..620] = 0
      Numo::SFloat.cast(s)
    end

    it 'matches its Ruby mirror sample for sample' do
      DB_SHAPER_CURVES.each do |name, (points, negative)|
        [[:line, 1.0, :linear, :line], [:silence, 0.6, :linear, :unity], [:unity, 1.0, :cubic, :unity]].each do |below, mix, interpolation, above|
          node = input(signal).shape_db(db_points(points), negative: negative && db_points(negative), below: below, above: above, mix: mix, interpolation: interpolation)
          c = SpecBuffers.join(3.times.map { node.sample(400).dup })
          coeffs = node.instance_variable_get(:@coeffs)
          state = [0.0, 0.0, 0.0, 0]
          r = SpecBuffers.join(signal.to_a.each_slice(400).map { |s|
            MB::Sound::GraphNode::CurveShaper.shape_curve_ruby(Numo::SFloat.cast(s), 4, coeffs, nil, nil, nil, DBS::MAP, DBS::EDGES, false, state)
          })
          expect(c).to eq(r), "#{name} #{below} #{mix} #{interpolation}"
        end
      end
    end

    # A slow sine: the ADAA output is the curve's average between each pair
    # of samples, so it is close to the exact shaper at their midpoint.
    # They part most where the curve bends: at corners (fold_back's -12 dB,
    # gate's -30 dB) and next to zero crossings, where one step spans tens
    # of dB (measured 2026-11-04: soft_knee 3.1e-4, asymmetric 3.3e-4,
    # fold_back 6.5e-4, gate 2.1e-3, fuzz 5.1e-3).
    {
      soft_knee: 5e-4, asymmetric: 5e-4, fold_back: 1e-3, gate: 3e-3, fuzz: 1e-2,
    }.each do |name, tolerance|
      it "stays within #{tolerance} of the exact #{name} curve at the midpoints of a 50 Hz sine" do
        t = Numo::DFloat.new(4800).seq
        x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 50 / 48000) * 0.9)
        out = input(x).shape_db(name).sample(4800)
        mid = (x[1..] + x[0...-1]) * 0.5
        exact = input(x).ashape_db(name).plain(mid)
        expect((out[2..] - exact[1..]).abs.max).to be < tolerance
      end
    end

    it 'chords cubic curves within 0.01 dB' do
      t = Numo::DFloat.new(4800).seq
      x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 20 / 48000) * 0.9)
      out = input(x).shape_db(:soft_knee).sample(4800)
      mid = (x[1..] + x[0...-1]) * 0.5
      exact = input(x).ashape_db(:soft_knee).plain(mid)
      big = exact.abs.gt(0.01).where
      ratio_db = 20 * Numo::NMath.log10((out[1..][big] / exact[big]).abs)
      expect(ratio_db[2..].abs.max).to be < 0.012
    end

    it 'passes a unity curve with only a half-sample allpass (flat level at 16 kHz)' do
      [1000, 16000].each do |f|
        node = f.hz.sine.at(0.5).shape_db(-84.db => -84.db, 0.db => 0.db)
        node.sample(4800)
        data = node.sample(48000)
        rms = Math.sqrt((data**2).mean)
        expect(20 * Math.log10(rms / (0.5 / Math.sqrt(2)))).to be_within(0.01).of(0), "#{f} Hz"
      end
    end


    # Measured 2026-11-04 (amplitude 0.9): 3 kHz 9.4-24 dB less aliasing
    # (softclip 10.9), 8 kHz 18-32 dB (softclip 20.4)
    %i[soft_knee fuzz fold_back gate asymmetric].each do |name|
      it "reduces aliasing of #{name} by at least 8 dB at 3 kHz" do
        k = 1025
        f = k * 48000.0 / 16384
        expect(alias_db(f.hz.sine.at(0.9).shape_db(name), k)).to be < alias_db(f.hz.sine.at(0.9).ashape_db(name), k) - 8
      end
    end
  end

  it 'gives the same output at any buffer size' do
    expect_invariant(-> { (110.hz.saw.at(0.5) + 0.3.hz.lfo.at(0.4)).shape_db(:asymmetric, mix: 0.8) }, seconds: 0.5)
    expect_invariant(-> { 110.hz.saw.ashape_db(:fold_back) }, seconds: 0.5)
  end

  describe 'vertical steps' do
    let(:step) { [[-84.db, -84.db], [-34.db, -40.db], [-34.db, -12.db], [0.db, -6.db]] }

    it 'jumps at the step, taking the second point\'s output on it and above' do
      t = DBS.transfer(step, {}, :linear)
      expect(t.call(-34.0)).to eq(-12.0)
      expect(t.call(-34.0 - 1e-9)).to be_within(1e-6).of(-40.0)
      expect(t.call(-37.0)).to be_within(1e-9).of(-84 + 44 * 47 / 50.0)
    end

    it 'takes a step as an output pair in a Hash' do
      a = input(levels).ashape_db(-84.db => -84.db, -34.db => [-40.db, -12.db], 0.db => -6.db).sample(levels.length)
      b = input(levels).ashape_db(step).sample(levels.length)
      expect(a).to eq(b)
      expect(110.hz.saw.shape_db(-84.db => -84.db, -34.db => [-40.db, -12.db], 0.db => -6.db).to_ruby).to eq('110.hz.saw.shape_db(-84.db => -84.db, -34.db => [-40.db, -12.db], 0.db => -6.db)')
    end

    it 'integrates across steps in closed form (the antiderivative bends, never jumps)' do
      node = input(levels).shape_db(db_points(DB_SHAPER_CURVES['steps up and down'][0]), negative: db_points(DB_SHAPER_CURVES['steps up and down'][1]))
      c = node.instance_variable_get(:@rows)
      [[0.005, 0.05], [0.05, 0.4], [-0.3, -0.05], [-0.5, 0.5]].each do |lo, hi|
        n = 200_000
        h = (hi - lo) / n
        numeric = (0...n).sum { |k| DBS.form_f(c, lo + (k + 0.5) * h) } * h
        expect(DBS.form_integral(c, hi) - DBS.form_integral(c, lo)).to be_within(2e-6 * (hi - lo).abs).of(numeric), "#{lo}..#{hi}"
      end
    end

    it 'antialiases across a step: the exact curve at the midpoints away from it, between both sides on it' do
      t = Numo::DFloat.new(4800).seq
      x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 50 / 48000) * 0.9)
      out = input(x).shape_db(step).sample(4800)
      exact = input(x).ashape_db(step)
      mid = exact.plain((x[1..] + x[0...-1]) * 0.5)
      ends_a = exact.plain(x[0...-1])
      ends_b = exact.plain(x[1..])
      edge = 10**(-34 / 20.0)
      (2...4799).each do |i|
        a, b = x[i - 1].abs, x[i].abs
        if (a - edge) * (b - edge) <= 0 && x[i - 1] * x[i] > 0
          lo, hi = [ends_a[i - 1], ends_b[i - 1]].minmax
          expect(out[i]).to be_between(lo - 1e-4, hi + 1e-4), "sample #{i} straddles the step"
        elsif [a, b].min > edge * 1.05 || [a, b].max < edge / 1.05
          expect(out[i]).to be_within(5e-4).of(mid[i - 1]), "sample #{i}"
        end
      end
    end

    it 'reduces aliasing of a step by at least 8 dB at 3 kHz' do
      k = 1025
      f = k * 48000.0 / 16384
      expect(alias_db(f.hz.sine.at(0.9).shape_db(step), k)).to be < alias_db(f.hz.sine.at(0.9).ashape_db(step), k) - 8
    end

    it 'refuses steps at the ends, three points at one input, and steps in compand' do
      expect { 1.constant.shape_db([[-34.db, -40.db], [-34.db, -12.db], [0.db, 0.db]]) }.to raise_error(ArgumentError, /both sides/)
      expect { 1.constant.shape_db([[-60.db, -60.db], [0.db, -40.db], [0.db, -12.db]]) }.to raise_error(ArgumentError, /both sides/)
      expect { 1.constant.shape_db([[-60.db, -60.db], [-34.db, -40.db], [-34.db, -30.db], [-34.db, -12.db], [0.db, 0.db]]) }.to raise_error(ArgumentError, /three/)
      expect { 1.constant.compand(-60.db => -60.db, -34.db => [-40.db, -12.db], 0.db => 0.db) }.to raise_error(ArgumentError, /must differ/)
    end
  end

  describe 'settings' do
    it 'reads points by the dB rule (bare numbers are linear gains)' do
      a = input(Numo::SFloat[0.3]).ashape_db(0.001 => 0.01, 1 => 0.5).sample(1)
      b = input(Numo::SFloat[0.3]).ashape_db(-60.db => -40.db, 0.db => -6.0206.db).sample(1)
      expect(a[0]).to be_within(1e-5).of(b[0])
      expect { 1.constant.shape_db(-60 => -40, 0 => 0) }.to raise_error(ArgumentError, /linear gain/)
    end

    it 'uses presets, with options over them' do
      expect(DBS.preset_names).to include(:soft_knee, :fuzz, :fold_back, :gate, :asymmetric)
      a = input(Numo::SFloat[0.5]).ashape_db.sample(1)[0]
      b = input(Numo::SFloat[0.5]).ashape_db(:soft_knee).sample(1)[0]
      expect(a).to eq(b)
      half = input(Numo::SFloat[0.5]).ashape_db(:fuzz, mix: 0.5).sample(1)[0]
      full = input(Numo::SFloat[0.5]).ashape_db(:fuzz).sample(1)[0]
      expect(half).to be_within(1e-6).of(0.5 + 0.5 * (full - 0.5))
      expect { 1.constant.shape_db(:fuz) }.to raise_error(ArgumentError, /fuzz/)
    end

    it 'refuses a first segment that would make quiet input louder below it' do
      expect { 1.constant.shape_db(-40.db => -10.db, -20.db => -10.db, 0.db => -6.db) }.to raise_error(ArgumentError, /below: :unity/)
      out = input(Numo::SFloat[1e-4]).ashape_db(-40.db => -10.db, -20.db => -10.db, 0.db => -6.db, below: :unity).sample(1)
      expect(20 * Math.log10(out[0])).to be_within(1e-3).of(-10 - 40)
    end

    it 'rejects unknown options and modes' do
      expect { 1.constant.shape_db(:fuzz, belwo: :line) }.to raise_error(ArgumentError)
      expect { 1.constant.shape_db(:fuzz, below: :floor) }.to raise_error(ArgumentError, /below/)
      expect { 1.constant.shape_db(:fuzz, above: :silence) }.to raise_error(ArgumentError, /above/)
      expect { 1.constant.shape_db(:fuzz, negative: :flip) }.to raise_error(ArgumentError, /mirror/)
      expect { 1.constant.shape_db(:fuzz, mix: 2) }.to raise_error(ArgumentError, /mix/)
    end

    it 'prints and loads as Ruby' do
      g = 110.hz.saw.shape_db(-60.db => -30.db, -20.db => -6.db, 0.db => -3.db, negative: { -60.db => -60.db, 0.db => -12.db }, below: :unity, mix: 0.8)
      code = g.to_ruby
      expect(code).to eq('110.hz.saw.shape_db(-60.db => -30.db, -20.db => -6.db, 0.db => -3.db, negative: { -60.db => -60.db, 0.db => -12.db }, below: :unity, mix: 0.8)')
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
      a = SpecBuffers.join(3.times.map { g.sample(400).dup })
      b = SpecBuffers.join(3.times.map { loaded.sample(400).dup })
      expect(b).to eq(a)
      expect(110.hz.saw.ashape_db(:fuzz).to_ruby).to eq('110.hz.saw.ashape_db(:fuzz)')
    end

    it 'works on channel bundles' do
      b = MB::Sound.stereo(0.5.constant, -0.25.constant).ashape_db(:soft_knee)
      out = b.map { |c| c.sample(1)[0] }
      expect(out[0]).to be > 0
      expect(out[1]).to be < 0
    end
  end
end
