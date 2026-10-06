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

        it 'multiplies exactly like Numo' do
          constants.each do |c|
            (0..4).each do |n|
              sampled = inputs.first(n).map { |v| [v, nil] }
              expected = numo_product(out_class.zeros(length), c, sampled)
              out = out_class.zeros(length)
              result = MB::Sound::FastArithmetic.product(out, c, sampled)
              expect(result).to equal(out)
              expect(out.to_binary).to eq(expected.to_binary), "constant #{c}, #{n} inputs"
            end
          end
        end

        it 'mixes exactly like Numo' do
          constants.each do |c|
            (0..4).each do |n|
              sampled = inputs.first(n).map.with_index { |v, i| [v, gains[(i + n) % gains.length]] }
              expected = numo_mix(out_class.zeros(length), out_class.zeros(length), c, sampled)
              out = out_class.zeros(length)
              result = MB::Sound::FastArithmetic.mix(out, c, sampled)
              expect(result).to equal(out)
              expect(out.to_binary).to eq(expected.to_binary), "constant #{c}, gains #{sampled.map(&:last)}"
            end
          end
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
end
