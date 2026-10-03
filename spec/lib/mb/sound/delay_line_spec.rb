RSpec.describe(MB::Sound::DelayLine, :aggregate_failures) do
  let(:ramp) { Numo::SFloat.new(10).seq + 1 }

  describe '#write and #read' do
    it 'reads the block back at a delay' do
      line = described_class.new(32)
      line.write(ramp)
      expect(line.read(10, 0)).to eq(ramp)
      expect(line.read(10, 3)).to eq(Numo::SFloat[0, 0, 0, 1, 2, 3, 4, 5, 6, 7])

      line.write(ramp + 10)
      expect(line.read(10, 3)).to eq(Numo::SFloat[8, 9, 10, 11, 12, 13, 14, 15, 16, 17])
    end

    it 'interpolates fractional delays' do
      line = described_class.new(32)
      line.write(ramp)
      expect(line.read(10, 1.25).to_a).to eq([0, 0.75, 1.75, 2.75, 3.75, 4.75, 5.75, 6.75, 7.75, 8.75])
      expect(line.read(3, Numo::SFloat[0, 0.5, 2]).to_a).to eq([1, 1.5, 1])
    end

    it 'clamps delays to the buffer' do
      line = described_class.new(60)
      line.write(ramp)
      expect(line.read(10, -3)).to eq(ramp)
      expect(line.read(10, 100)).to eq(line.read(10, line.capacity - 2))
    end
  end

  describe '#prepare' do
    it 'promotes the buffer to complex for complex input' do
      line = described_class.new(16)
      line.prepare(4, 2, Numo::SComplex)
      expect(line.buffer).to be_a(Numo::SComplex)
    end

    it 'grows the buffer, keeping the stored audio in place' do
      block = Numo::SFloat.new(100).seq + 1
      line = described_class.new(200)
      line.prepare(100, 4).write(block)        # 1..100
      line.prepare(100, 4).write(block + 100)  # 101..200
      expect(line.capacity).to eq(200)

      line.prepare(100, 250)
      expect(line.capacity).to be >= 100 + 250 + described_class::MARGIN
      line.write(block + 200)                  # 201..300
      expect(line.read(100, 150).to_a).to eq((51..150).to_a)
      expect(line.read(100, 250).to_a).to eq([0] * 50 + (1..50).to_a) # written before growing
    end
  end

  describe 'interpolation modes' do
    let(:sine) { Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(400).seq * 0.3)) }

    it 'read whole-sample delays exactly (cubic) or nearly (sinc)' do
      line = described_class.new(500)
      line.write(sine)
      expected = line.read(400, 37)
      expect(line.read(400, 37, interpolation: :cubic)).to eq(expected)
      expect(line.read(400, 37, interpolation: :sinc)).to all_be_within(1e-5).of_array(expected)
    end

    it 'interpolate high frequencies more accurately than linear' do
      # 0.3 rad/sample is ~2.3 kHz at 48 kHz, 2.0 is ~15 kHz
      errors = [0.3, 2.0].to_h { |w|
        tone = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(400).seq * w))
        ideal = Numo::NMath.sin((Numo::DFloat.new(400).seq - 37.4) * w)
        line = described_class.new(500)
        line.write(tone)
        [w, described_class::INTERPOLATION.keys.to_h { |mode|
          [mode, (Numo::DFloat.cast(line.read(400, 37.4, interpolation: mode)) - ideal)[100..].abs.max]
        }]
      }

      expect(errors[0.3][:cubic]).to be < errors[0.3][:linear] / 20
      expect(errors[0.3][:sinc]).to be < errors[0.3][:linear] / 10
      expect(errors[2.0][:cubic]).to be < errors[2.0][:linear]
      expect(errors[2.0][:sinc]).to be < errors[2.0][:cubic] / 100
    end

    it 'rejects unknown modes' do
      expect { described_class.new(100).read(10, 1, interpolation: :magic) }.to raise_error(ArgumentError, /interpolation/)
    end
  end

  describe '#feedback' do
    it 'feeds the delayed signal back into the delay' do
      line = described_class.new(32)
      impulse = Numo::SFloat.zeros(12).tap { |d| d[0] = 1 }
      out = line.feedback(impulse, 4, 0.5)
      expect(out.to_a).to eq([0, 0, 0, 0, 1, 0, 0, 0, 0.5, 0, 0, 0])
    end
  end

  describe 'C and Ruby versions' do
    # Two identical delay lines holding +capacity+ samples of random audio
    def lines(capacity, type)
      a = described_class.new(capacity, type: type)
      b = described_class.new(capacity, type: type)
      history = type.new(capacity).rand(-1, 1)
      history = type.cast(history + 1i * type.new(capacity).rand(-1, 1)) if type == Numo::SComplex
      [a, b].each { |l| l.write(history) }
      [a, b]
    end

    [Numo::SFloat, Numo::SComplex].each do |type|
      context "with #{type}" do
        let(:block) {
          d = type.new(160).rand(-1, 1)
          type == Numo::SComplex ? type.cast(d + 1i * Numo::SFloat.new(160).rand(-1, 1)) : d
        }

        {
          'zero' => 0,
          'an integer delay' => 37,
          'a fractional delay' => 37.37,
          'a negative delay (clamped)' => -2.5,
          'a delay past the buffer (clamped)' => 5000,
          'per-sample SFloat delays' => Numo::SFloat.new(160).rand(-5, 1100),
          'per-sample DFloat delays' => Numo::DFloat.new(160).rand(0, 300),
        }.each do |desc, delay|
          described_class::INTERPOLATION.each_key do |mode|
            it "read the same for #{desc} (#{mode})" do
              c, r = lines(1000, type)
              cs = [3.0]
              rs = [3.0]
              2.times do
                c.write(block)
                r.write(block)
                expect(c.read(160, delay, interpolation: mode, state: cs)).to eq(r.read_ruby(160, delay, interpolation: mode, state: rs))
                expect(cs).to eq(rs)
              end
            end

            it "feed back the same for #{desc} (#{mode})" do
              c, r = lines(1000, type)
              gain = type == Numo::SComplex ? 0.3 - 0.4i : -0.7
              cs = []
              rs = []
              2.times do
                expect(c.feedback(block, delay, gain, interpolation: mode, state: cs)).to eq(r.feedback_ruby(block, delay, gain, interpolation: mode, state: rs))
                expect(c.buffer).to eq(r.buffer)
                expect(c.write_offset).to eq(r.write_offset)
                expect(cs).to eq(rs)
              end
            end
          end
        end

        it 'feed back the same with per-sample gains' do
          c, r = lines(500, type)
          gains = Numo::SFloat.new(160).rand(-0.9, 0.9)
          delays = Numo::SFloat.new(160).rand(0, 120)
          expect(c.feedback(block, delays, gains)).to eq(r.feedback_ruby(block, delays, gains))
          expect(c.buffer).to eq(r.buffer)
        end
      end
    end
  end
end
