RSpec.describe(MB::Sound::FastArithmetic) do
  # Inputs with signed zeros, infinities, and NaNs besides random values, so
  # bit-for-bit comparisons catch any reordered or fused operation.
  def make_input(cls, length, seed)
    rng = Random.new(seed)
    real = Array.new(length) { rng.rand(-2.0..2.0) }
    real[0] = -0.0
    real[1] = 0.0 if length > 1
    real[2] = Float::INFINITY if length > 8
    real[3] = Float::NAN if length > 8
    if cls == Numo::SComplex || cls == Numo::DComplex
      imag = Array.new(length) { rng.rand(-2.0..2.0) }
      imag[1] = -0.0 if length > 1
      imag[4] = -Float::INFINITY if length > 8
      cls.cast(real.zip(imag).map { |r, i| Complex(r, i) })
    else
      cls.cast(real)
    end
  end

  # The Ruby mirror: the Numo code of the Multiplier fast path
  def numo_product(out, constant, sampled)
    out.fill(constant)
    sampled.each { |v, _| out.inplace * v }
    out.not_inplace!
  end

  # The Ruby mirror: the Numo code of the Mixer fast path
  def numo_mix(out, tmp, constant, sampled)
    out.fill(constant)
    sampled.each do |v, gain|
      if gain == 1
        out.inplace + v
      else
        tmp.fill(gain).inplace * v
        out.inplace + tmp
      end
    end
    out.not_inplace!
  end

  combos = {
    Numo::SFloat => [Numo::SFloat],
    Numo::DFloat => [Numo::DFloat],
    Numo::SComplex => [Numo::SComplex, Numo::SFloat],
    Numo::DComplex => [Numo::DComplex, Numo::DFloat],
  }

  combos.each do |out_class, input_classes|
    complex = out_class == Numo::SComplex || out_class == Numo::DComplex
    constants = [1, 0.37, -2, Rational(1, 3)]
    constants << Complex(0.5, -0.25) if complex
    gains = [1, 1.0, -0.5, 0.123456789, Rational(2, 7)]
    gains << Complex(-0.3, 0.7) << Complex(1, 0) if complex

    [1, 7, 128, 129].each do |length|
      context "with #{out_class} output, #{input_classes.map(&:name).join('/')} inputs, length #{length}" do
        let(:inputs) {
          Array.new(4) { |i| make_input(input_classes[i % input_classes.length], length, length * 10 + i) }
        }

        def complex_class?(c)
          c == Numo::SComplex || c == Numo::DComplex
        end

        # Products of two truly complex factors are left to Numo (see
        # fast_arithmetic.c): a complex constant or input followed by
        # another complex input
        def declined_product?(out_class, constant, sampled)
          return false unless complex_class?(out_class)
          factors = sampled.count { |v, _| complex_class?(v.class) }
          factors += 1 if constant.is_a?(Complex) && constant.imag != 0 && factors > 0
          factors > 1
        end

        # A complex input times a gain with an imaginary part
        def declined_mix?(out_class, sampled)
          complex_class?(out_class) && sampled.any? { |v, g| complex_class?(v.class) && g.is_a?(Complex) && g.imag != 0 }
        end

        it 'multiplies exactly like Numo, leaving complex by complex products to Numo' do
          computed = 0
          constants.each do |c|
            (0..4).each do |n|
              [inputs.first(n), inputs.select { |v| v.class == input_classes.last }.first(n)].each do |list|
                sampled = list.map { |v| [v, nil] }
                expected = numo_product(out_class.zeros(length), c, sampled)
                out = out_class.zeros(length)
                result = MB::Sound::FastArithmetic.product(out, c, sampled)

                if declined_product?(out_class, c, sampled)
                  expect(result).to be_nil
                  expect(out).to eq(out_class.zeros(length))
                else
                  computed += 1
                  expect(result).to equal(out)
                  expect(out.to_binary).to eq(expected.to_binary), "constant #{c}, #{n} inputs"
                end
              end
            end
          end
          expect(computed).to be >= constants.length * 2
        end

        it 'mixes exactly like Numo, leaving complex inputs with gains to Numo' do
          computed = 0
          constants.each do |c|
            (0..4).each do |n|
              [0, 1, 2].each do |offset|
                sampled = inputs.first(n).map.with_index { |v, i| [v, gains[(i + n + offset) % gains.length]] }
                expected = numo_mix(out_class.zeros(length), out_class.zeros(length), c, sampled)
                out = out_class.zeros(length)
                result = MB::Sound::FastArithmetic.mix(out, c, sampled)

                if declined_mix?(out_class, sampled)
                  expect(result).to be_nil
                else
                  computed += 1
                  expect(result).to equal(out)
                  expect(out.to_binary).to eq(expected.to_binary), "constant #{c}, gains #{sampled.map(&:last)}"
                end
              end
            end
          end
          expect(computed).to be > constants.length * 3
        end
      end
    end
  end

  it 'writes into a view at its offset and leaves the rest alone' do
    base = Numo::SFloat.new(10).seq
    view = base[3...7]
    a = Numo::SFloat[1, 2, 3, 4]
    expect(MB::Sound::FastArithmetic.product(view, 2, [[a, nil]])).to equal(view)
    expect(base.to_a).to eq([0, 1, 2, 2, 4, 6, 8, 7, 8, 9])

    expect(MB::Sound::FastArithmetic.mix(view, 1, [[a, 1], [a, 0.5]])).to equal(view)
    expect(base.to_a).to eq([0, 1, 2, 2.5, 4, 5.5, 7, 7, 8, 9])
  end

  it 'reads input views at their offsets' do
    base = Numo::SFloat.new(10).seq
    out = Numo::SFloat.zeros(3)
    expect(MB::Sound::FastArithmetic.product(out, 1, [[base[5...8], nil]])).to equal(out)
    expect(out.to_a).to eq([5, 6, 7])
  end

  it 'reads frozen inputs' do
    a = Numo::SFloat[1, 2, 3].freeze
    out = Numo::SFloat.zeros(3)
    expect(MB::Sound::FastArithmetic.mix(out, 0, [[a, 2]])).to equal(out)
    expect(out.to_a).to eq([2, 4, 6])
  end

  describe 'returns nil without writing' do
    let(:out) { Numo::SFloat.zeros(4) }

    def expect_nil(out, constant, sampled)
      before = out.dup
      expect(MB::Sound::FastArithmetic.product(out, constant, sampled)).to be_nil
      expect(MB::Sound::FastArithmetic.mix(out, constant, sampled)).to be_nil
      expect(out).to eq(before)
    end

    it 'for an input of another length' do
      expect_nil(out, 1, [[Numo::SFloat.ones(3), 1]])
    end

    it 'for an input type that would promote the output' do
      expect_nil(out, 1, [[Numo::DFloat.ones(4), 1]])
      expect_nil(out, 1, [[Numo::SComplex.ones(4), 1]])
      expect_nil(Numo::SComplex.zeros(4), 1, [[Numo::DFloat.ones(4), 1]])
    end

    it 'for a complex constant with a real output' do
      expect_nil(out, Complex(1, 1), [[Numo::SFloat.ones(4), 1]])
    end

    it 'for a non-contiguous input' do
      expect_nil(out, 1, [[Numo::SFloat.ones(8)[(0..) % 2], 1]])
    end

    it 'for a frozen output' do
      expect_nil(out.freeze, 1, [[Numo::SFloat.ones(4), 1]])
    end

    it 'for a frozen output view' do
      base = Numo::SFloat.zeros(8)
      view = base[0...4]
      base.freeze
      expect_nil(view, 1, [[Numo::SFloat.ones(4), 1]])
    end

    it 'for a non-NArray input' do
      expect_nil(out, 1, [[[1, 2, 3, 4], 1]])
    end

    it 'for a complex gain with a real output (mix only)' do
      expect(MB::Sound::FastArithmetic.mix(out, 1, [[Numo::SFloat.ones(4), Complex(0, 1)]])).to be_nil
      expect(out).to eq(Numo::SFloat.zeros(4))
    end
  end

  describe 'complex products (FMA safety)' do
    let(:c1) { Numo::SComplex[1 + 2i, 3 - 1i] }
    let(:c2) { Numo::SComplex[0.5 - 2i, -1 + 1i] }
    let(:r) { Numo::SFloat[2, -3] }

    it 'computes one complex factor among real ones' do
      out = Numo::SComplex.zeros(2)
      expect(MB::Sound::FastArithmetic.product(out, 0.5, [[r, nil], [c1, nil], [r, nil]])).to equal(out)
      expect(out.to_binary).to eq(numo_product(Numo::SComplex.zeros(2), 0.5, [[r, nil], [c1, nil], [r, nil]]).to_binary)
      expect(MB::Sound::FastArithmetic.product(out, 2i, [[r, nil], [r, nil]])).to equal(out)
      expect(MB::Sound::FastArithmetic.mix(out, 1i, [[c1, 0.25], [r, 2 - 1i], [c2, 1]])).to equal(out)
    end

    it 'leaves two truly complex factors to Numo' do
      out = Numo::SComplex.zeros(2)
      expect(MB::Sound::FastArithmetic.product(out, 1, [[c1, nil], [c2, nil]])).to be_nil
      expect(MB::Sound::FastArithmetic.product(out, 1 + 1i, [[c1, nil]])).to be_nil
      expect(MB::Sound::FastArithmetic.mix(out, 0, [[c1, 0.5 + 0.5i]])).to be_nil
      expect(out).to eq(Numo::SComplex.zeros(2))
    end
  end

  describe '.min_max' do
    def bits(v)
      [v].pack('d')
    end

    [Numo::SFloat, Numo::DFloat].each do |cls|
      it "matches Numo's min and max for #{cls}" do
        nan = Float::NAN
        cases = [
          make_input(cls, 129, 5),
          cls[1],
          cls[nan, 3, -2, nan, 5],
          cls[nan, nan],
          cls[-0.0, 0.0, -0.0],
          cls[0.0, -0.0],
          cls[Float::INFINITY, -Float::INFINITY, 1],
          make_input(cls, 129, 9)[3..],
        ]
        result = [nil, nil]
        cases.each do |buf|
          expect(MB::Sound::FastArithmetic.min_max(buf, result)).to equal(result)
          expect(bits(result[0])).to eq(bits(buf.min.to_f)), "min of #{buf.to_a}"
          expect(bits(result[1])).to eq(bits(buf.max.to_f)), "max of #{buf.to_a}"
        end
      end
    end

    it 'returns nil for complex, empty, or non-contiguous buffers' do
      r = [1, 2]
      expect(MB::Sound::FastArithmetic.min_max(Numo::SComplex[1, 2], r)).to be_nil
      expect(MB::Sound::FastArithmetic.min_max(Numo::SFloat[], r)).to be_nil
      expect(MB::Sound::FastArithmetic.min_max(Numo::SFloat.new(8).seq[(0..) % 2], r)).to be_nil
      expect(r).to eq([1, 2])
    end
  end

  describe '.divide and .power' do
    [Numo::SFloat, Numo::DFloat].each do |cls|
      it "divide #{cls} buffers exactly like Numo" do
        a = make_input(cls, 129, 11)
        b = make_input(cls, 129, 12)
        [b, 20, -3, 0.37, 1e-30, 0].each do |d|
          expected = a.dup.inplace / d
          out = a.dup
          expect(MB::Sound::FastArithmetic.divide(out, d)).to equal(out)
          expect(out.to_binary).to eq(expected.not_inplace!.to_binary), "divisor #{d.inspect}"
        end
      end

      it "raise #{cls} buffers to powers exactly like Numo" do
        a = make_input(cls, 129, 13).abs * 10
        b = make_input(cls, 129, 14)
        [[a, b], [cls.new(129).fill(10), b], [a - 5, cls.new(129).fill(0.5)], [a - 5, cls.new(129).fill(3)]].each do |x, y|
          expected = x.dup.inplace ** y
          out = x.dup
          expect(MB::Sound::FastArithmetic.power(out, y)).to equal(out)
          expect(out.to_binary).to eq(expected.not_inplace!.to_binary)
        end
      end
    end

    it 'return nil for complex buffers, promotions, scalar exponents, or frozen outputs' do
      out = Numo::SFloat[1, 2]
      expect(MB::Sound::FastArithmetic.divide(Numo::SComplex[1, 2], 2)).to be_nil
      expect(MB::Sound::FastArithmetic.divide(out, Numo::DFloat[1, 2])).to be_nil
      expect(MB::Sound::FastArithmetic.divide(out, Rational(1, 3))).to be_nil
      expect(MB::Sound::FastArithmetic.divide(out, 2i)).to be_nil
      expect(MB::Sound::FastArithmetic.divide(out.dup.freeze, 2)).to be_nil
      expect(MB::Sound::FastArithmetic.power(out, 2)).to be_nil
      expect(MB::Sound::FastArithmetic.power(out, Numo::SFloat[1, 2, 3])).to be_nil
      expect(out.to_a).to eq([1, 2])
    end
  end

  describe '.circular_read and .circular_write' do
    [Numo::SFloat, Numo::DComplex].each do |cls|
      it "match MB::M for #{cls} at every offset and length" do
        source = make_input(cls, 13, 21)
        (-13...13).each do |offset|
          [1, 5, 12, 13].each do |length|
            target = cls.zeros(15)
            expected = MB::M.circular_read(source, offset, length, target: cls.zeros(15))
            expect(MB::Sound::FastArithmetic.circular_read(source, offset, length, target)).to equal(target)
            expect(target.to_binary).to eq(expected.to_binary), "read #{offset}, #{length}"

            data = make_input(cls, length, offset + 50)
            buf = source.dup
            expected = MB::M.circular_write(source.dup, data, offset)
            expect(MB::Sound::FastArithmetic.circular_write(buf, data, offset)).to equal(buf)
            expect(buf.to_binary).to eq(expected.to_binary), "write #{offset}, #{length}"
          end
        end
      end
    end

    it 'return nil for bad offsets and lengths, other types, and frozen targets' do
      s = Numo::SFloat.new(8).seq
      t = Numo::SFloat.zeros(8)
      expect(MB::Sound::FastArithmetic.circular_read(s, 8, 2, t)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, 0, 0, t)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_write(t, Numo::SFloat[], 0)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, -9, 2, t)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, 0, 9, Numo::SFloat.zeros(9))).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, 0, 4, Numo::SFloat.zeros(3))).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, 0, 4, Numo::DFloat.zeros(4))).to be_nil
      expect(MB::Sound::FastArithmetic.circular_read(s, 0, 4, t.dup.freeze)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_write(t, Numo::SFloat.ones(9), 0)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_write(t, Numo::SFloat.ones(2), 8)).to be_nil
      expect(MB::Sound::FastArithmetic.circular_write(t, Numo::DFloat.ones(2), 0)).to be_nil
      expect(t).to eq(Numo::SFloat.zeros(8))
    end
  end

  describe '.wet_dry' do
    it "matches Filter::Delay's Numo mix exactly" do
      delayed = make_input(Numo::SFloat, 129, 31)
      data = make_input(Numo::SFloat, 129, 32)
      [[0.5, 0.25], [1, 0], [0.3, 1], [-0.7, 0.123], [2, nil]].each do |wet, dry|
        expected = wet * delayed
        expected = expected + dry * data if dry && dry != 0
        out = Numo::SFloat.zeros(129)
        expect(MB::Sound::FastArithmetic.wet_dry(out, delayed, wet, data, dry && dry != 0 ? dry : nil)).to equal(out)
        expect(out.to_binary).to eq(expected.to_binary), "wet #{wet}, dry #{dry}"

        in_place = data.dup
        MB::Sound::FastArithmetic.wet_dry(in_place, delayed, wet, in_place, dry && dry != 0 ? dry : nil)
        expect(in_place.to_binary).to eq(expected.to_binary)
      end
    end

    it 'returns nil for complex buffers, NArray gains, or other lengths' do
      out = Numo::SFloat.zeros(4)
      expect(MB::Sound::FastArithmetic.wet_dry(out, Numo::SComplex.ones(4), 1, Numo::SFloat.ones(4), 1)).to be_nil
      expect(MB::Sound::FastArithmetic.wet_dry(out, Numo::SFloat.ones(4), Numo::SFloat.ones(4), Numo::SFloat.ones(4), 1)).to be_nil
      expect(MB::Sound::FastArithmetic.wet_dry(out, Numo::SFloat.ones(3), 1, Numo::SFloat.ones(4), 1)).to be_nil
      expect(MB::Sound::FastArithmetic.wet_dry(out, Numo::SFloat.ones(4), 1, Numo::SFloat.ones(3), 1)).to be_nil
      expect(out).to eq(Numo::SFloat.zeros(4))
    end
  end

  describe '.complex_part' do
    [[Numo::SComplex, Numo::SFloat], [Numo::DComplex, Numo::DFloat]].each do |src_class, out_class|
      it "copies the real and imaginary parts of #{src_class} like Numo" do
        src = make_input(src_class, 129, 41)
        [false, true].each do |imag|
          out = out_class.zeros(129)
          expect(MB::Sound::FastArithmetic.complex_part(out, src, imag)).to equal(out)
          expect(out.to_binary).to eq((imag ? src.imag : src.real).to_binary)
        end
      end
    end

    it 'returns nil for mismatched types, lengths, or a frozen output' do
      src = Numo::SComplex[1 + 2i, 3]
      expect(MB::Sound::FastArithmetic.complex_part(Numo::DFloat.zeros(2), src, false)).to be_nil
      expect(MB::Sound::FastArithmetic.complex_part(Numo::SFloat.zeros(3), src, false)).to be_nil
      expect(MB::Sound::FastArithmetic.complex_part(Numo::SFloat.zeros(2).freeze, src, false)).to be_nil
      expect(MB::Sound::FastArithmetic.complex_part(Numo::SFloat.zeros(2), Numo::SFloat[1, 2], false)).to be_nil
    end
  end

  describe '.copy' do
    [Numo::SFloat, Numo::DFloat, Numo::SComplex, Numo::DComplex].each do |cls|
      it "copies #{cls} buffers exactly" do
        src = make_input(cls, 129, 3)
        out = cls.zeros(129)
        expect(MB::Sound::FastArithmetic.copy(out, src)).to equal(out)
        expect(out.to_binary).to eq(src.to_binary)
      end
    end

    it 'copies between views' do
      base = Numo::SFloat.zeros(10)
      expect(MB::Sound::FastArithmetic.copy(base[2...5], Numo::SFloat.new(8).seq[4...7])).not_to be_nil
      expect(base.to_a).to eq([0, 0, 4, 5, 6, 0, 0, 0, 0, 0])
    end

    it 'returns nil for other types, lengths, layouts, or a frozen output' do
      out = Numo::SFloat.zeros(4)
      expect(MB::Sound::FastArithmetic.copy(out, Numo::DFloat.ones(4))).to be_nil
      expect(MB::Sound::FastArithmetic.copy(out, Numo::SFloat.ones(3))).to be_nil
      expect(MB::Sound::FastArithmetic.copy(out, Numo::SFloat.ones(8)[(0..) % 2])).to be_nil
      expect(MB::Sound::FastArithmetic.copy(out.dup.freeze, Numo::SFloat.ones(4))).to be_nil
      expect(MB::Sound::FastArithmetic.copy(out, [1, 2, 3, 4])).to be_nil
      expect(out).to eq(Numo::SFloat.zeros(4))
    end
  end

  describe '.pan' do
    let(:pan_laws) { MB::Sound::GraphNode::ChannelMixer::PanLaws }

    # Positions past the ends, both zeros, NaN, and random values
    let(:position) {
      rng = Random.new(3)
      Numo::SFloat.cast(Array.new(4000) { rng.rand * 2.4 - 1.2 } + [-1, 1, 0, -0.0, 0.5, -0.5, Float::NAN, 2, -3])
    }
    let(:input) {
      rng = Random.new(4)
      Numo::SFloat.cast(Array.new(position.length) { rng.rand * 2 - 1 })
    }

    [:equal_power, :linear, :minus_4_5db].each_with_index do |law, number|
      it "gives exactly PanLaws.gains and the products for #{law}" do
        left, right = pan_laws.gains(law, position)
        gains = Array.new(2) { Numo::SFloat.zeros(position.length) }
        outs = Array.new(2) { Numo::SFloat.zeros(position.length) }

        expect(MB::Sound::FastArithmetic.pan(number, position, input, gains, outs)).to equal(outs)
        expect(gains[0].to_binary).to eq(left.to_binary)
        expect(gains[1].to_binary).to eq(right.to_binary)
        expect(outs[0].to_binary).to eq((left * input).to_binary)
        expect(outs[1].to_binary).to eq((right * input).to_binary)
      end
    end

    it 'returns nil for other types, lengths, laws, or frozen outputs' do
      bufs = -> { Array.new(2) { Numo::SFloat.zeros(4) } }
      pos = Numo::SFloat.zeros(4)
      x = Numo::SFloat.ones(4)
      expect(MB::Sound::FastArithmetic.pan(0, Numo::DFloat.zeros(4), x, bufs.call, bufs.call)).to be_nil
      expect(MB::Sound::FastArithmetic.pan(0, pos, Numo::DFloat.ones(4), bufs.call, bufs.call)).to be_nil
      expect(MB::Sound::FastArithmetic.pan(0, Numo::SFloat.zeros(3), x, bufs.call, bufs.call)).to be_nil
      expect(MB::Sound::FastArithmetic.pan(3, pos, x, bufs.call, bufs.call)).to be_nil
      expect(MB::Sound::FastArithmetic.pan(0, pos, x, bufs.call, [Numo::SFloat.zeros(4), Numo::SFloat.zeros(4).freeze])).to be_nil
      expect(MB::Sound::FastArithmetic.pan(0, pos, x, bufs.call.take(1), bufs.call)).to be_nil
    end
  end

  it 'does not allocate objects for full real buffers' do
    out = Numo::SFloat.zeros(128)
    sampled = [[Numo::SFloat.ones(128), 0.5], [Numo::SFloat.ones(128), 1]]
    MB::Sound::FastArithmetic.product(out, 1, sampled)
    MB::Sound::FastArithmetic.mix(out, 1, sampled)

    # 1000 calls each; the loop and GC.stat itself may allocate a couple
    before = GC.stat(:total_allocated_objects)
    1000.times do
      MB::Sound::FastArithmetic.product(out, 1, sampled)
      MB::Sound::FastArithmetic.mix(out, 0.25, sampled)
    end
    expect(GC.stat(:total_allocated_objects) - before).to be < 10
  end

  describe '.scale' do
    # Bitwise comparison treating NaNs as equal
    def same(a, b)
      a.to_a.flatten.zip(b.to_a.flatten).all? { |x, y|
        xs = x.is_a?(Complex) ? [x.real, x.imag] : [x]
        ys = y.is_a?(Complex) ? [y.real, y.imag] : [y]
        xs.zip(ys).all? { |p, q| (p.nan? && q.nan?) || [p].pack('e') == [q].pack('e') }
      }
    end

    [Numo::SFloat, Numo::SComplex].each do |cls|
      it "multiplies #{cls} buffers in place like Numo, by an SFloat or a number" do
        [make_input(Numo::SFloat, 37, 5), 0.3, -2, 1e-3].each do |g|
          out = make_input(cls, 37, 9)
          expected = out.dup.inplace * g
          expect(MB::Sound::FastArithmetic.scale(out, g)).to equal(out)
          expect(same(out, expected)).to eq(true)
        end
      end
    end

    it 'scales a view in place' do
      buf = make_input(Numo::SFloat, 64, 2)
      expected = buf[0...20].dup * 0.5
      view = buf[0...20]
      MB::Sound::FastArithmetic.scale(view, 0.5)
      expect(same(buf[0...20], expected)).to eq(true)
    end

    it 'returns nil without changing the buffer for what it does not take' do
      out = make_input(Numo::SFloat, 16, 3)
      copy = out.dup
      expect(MB::Sound::FastArithmetic.scale(out, Numo::SFloat.zeros(15))).to be_nil
      expect(MB::Sound::FastArithmetic.scale(out, Numo::DFloat.zeros(16))).to be_nil
      expect(MB::Sound::FastArithmetic.scale(out, Complex(1, 1))).to be_nil
      expect(MB::Sound::FastArithmetic.scale(Numo::DFloat.zeros(16), 2)).to be_nil
      expect(MB::Sound::FastArithmetic.scale(out.dup.freeze, 2)).to be_nil
      expect(MB::Sound::FastArithmetic.scale(Numo::SFloat.zeros(4, 4), 2)).to be_nil
      expect(same(out, copy)).to eq(true)
    end
  end
end
