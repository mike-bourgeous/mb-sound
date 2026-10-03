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
      line = described_class.new(12)
      line.write(ramp)
      expect(line.read(10, -3)).to eq(ramp)
      expect(line.read(10, 100)).to eq(line.read(10, 10))
    end
  end

  describe '#prepare' do
    it 'promotes the buffer to complex for complex input' do
      line = described_class.new(16)
      line.prepare(4, 2, Numo::SComplex)
      expect(line.buffer).to be_a(Numo::SComplex)
    end

    it 'grows the buffer, keeping the stored audio in place' do
      line = described_class.new(16)
      line.prepare(10, 4).write(ramp)       # 1..10
      line.prepare(10, 4).write(ramp + 10)  # 11..20; the 16 newest are 5..20
      expect(line.capacity).to eq(16)

      line.prepare(10, 15)
      expect(line.capacity).to be >= 27
      line.write(ramp + 20)                 # 21..30
      expect(line.read(10, 15).to_a).to eq((6..15).to_a)
      expect(line.read(10, 16).to_a).to eq((5..14).to_a)
      expect(line.read(10, 17).to_a).to eq([0] + (5..13).to_a) # 4 was overwritten before growing
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
          it "read the same for #{desc}" do
            c, r = lines(1000, type)
            c.write(block)
            r.write(block)
            expect(c.read(160, delay)).to eq(r.read_ruby(160, delay))
          end

          it "feed back the same for #{desc}" do
            c, r = lines(1000, type)
            gain = type == Numo::SComplex ? 0.3 - 0.4i : -0.7
            expect(c.feedback(block, delay, gain)).to eq(r.feedback_ruby(block, delay, gain))
            expect(c.buffer).to eq(r.buffer)
            expect(c.write_offset).to eq(r.write_offset)
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
