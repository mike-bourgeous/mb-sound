RSpec.describe(MB::Sound::FastControl) do
  describe '.smooth' do
    # State and rings for moving averages of n1 and n2 samples, settled at
    # +value+.
    def setup(n1, n2, value = 0.0)
      [Numo::DFloat[value, value, 0, 0, 0, 0, n1 + n2 - 2], Numo::DFloat.zeros(n1), Numo::DFloat.zeros(n2)]
    end

    # A stepped control signal: random values held for random stretches.
    def stepped(length, seed)
      rng = Random.new(seed)
      x = Numo::SFloat.zeros(length)
      i = 0
      while i < length
        x[i..] = rng.rand(-2.0..2.0)
        i += rng.rand(1..300)
      end
      x
    end

    [[1, 1], [2, 3], [7, 7], [240, 240], [220, 221]].each do |n1, n2|
      it "matches the Ruby mirror exactly for #{n1} + #{n2} samples in odd pieces" do
        x = stepped(6000, n1 * 31 + n2)
        out_c = Numo::SFloat.zeros(x.length)
        out_r = Numo::SFloat.zeros(x.length)
        c = setup(n1, n2, x[0])
        r = setup(n1, n2, x[0])
        pos = 0
        [1, 37, 128, 500, 3].cycle do |n|
          break if pos >= x.length
          to = [pos + n, x.length].min
          MB::Sound::FastControl.smooth(x, out_c, pos, to, *c)
          MB::Sound::Notes::Smoother.smooth_ruby(x, out_r, pos, to, *r)
          pos = to
        end

        expect(out_c.to_a).to eq(out_r.to_a)
        expect(c.map(&:to_a)).to eq(r.map(&:to_a))
      end
    end

    it 'is exact once the input has held for the kernel' do
      x = Numo::SFloat.zeros(1000)
      x[10..] = 0.3
      out = Numo::SFloat.zeros(1000)
      st = setup(5, 6)
      MB::Sound::FastControl.smooth(x, out, 0, 1000, *st)
      expect(out[0...10].to_a.uniq).to eq([0.0])
      expect(out[18]).not_to eq(x[18])
      expect(out[19..].to_a.uniq).to eq([x[19]]) # a 10-sample kernel
      expect(st[0][6]).to eq(9)
    end

    it 'leaves the samples outside the range alone' do
      x = Numo::SFloat.ones(10)
      out = Numo::SFloat.new(10).fill(7)
      MB::Sound::FastControl.smooth(x, out, 3, 6, *setup(2, 2))
      expect(out.to_a).to eq([7, 7, 7, 0.25, 0.75, 1, 7, 7, 7, 7].map(&:to_f))
    end

    it 'checks its arguments' do
      x = Numo::SFloat.zeros(10)
      out = Numo::SFloat.zeros(10)
      st = setup(2, 2)
      expect { MB::Sound::FastControl.smooth(x, out, 0, 11, *st) }.to raise_error(RangeError)
      expect { MB::Sound::FastControl.smooth(x, out, 5, 4, *st) }.to raise_error(RangeError)
      expect { MB::Sound::FastControl.smooth(x, Numo::SFloat.zeros(9), 0, 9, *st) }.to raise_error(ArgumentError, /as many/)
      expect { MB::Sound::FastControl.smooth(x, out.freeze, 0, 9, *st) }.to raise_error(FrozenError)
      expect { MB::Sound::FastControl.smooth(Numo::DFloat.zeros(10), out, 0, 9, *st) }.to raise_error(ArgumentError, /SFloat/)
      expect { MB::Sound::FastControl.smooth(x, Numo::SFloat.zeros(10), 0, 9, Numo::DFloat.zeros(6), *st[1..]) }.to raise_error(ArgumentError, /state/)
      expect { MB::Sound::FastControl.smooth(x, Numo::SFloat.zeros(10), 0, 9, st[0], Numo::DFloat.zeros(0), st[2]) }.to raise_error(ArgumentError, /Ring 1/)
      bad = st[0].dup
      bad[4] = 2
      expect { MB::Sound::FastControl.smooth(x, Numo::SFloat.zeros(10), 0, 9, bad, *st[1..]) }.to raise_error(ArgumentError, /positions/)
    end
  end
end
