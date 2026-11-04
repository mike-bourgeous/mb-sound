RSpec.describe(MB::Sound::GraphNode::ChannelMixer::PanLaws) do
  # ACID's pan laws as the research-acd-format-linux study (df0870d6,
  # research/acd-format/acd/audio_render.rb) modeled and nulled them against
  # ACID's render of its pan-law reference project: [ll, rl, lr, rr], left
  # out = ll L + rl R, right out = lr L + rr R (a copy, not a require of the
  # research code).
  acid_balance = { balance_0db: 1.0, balance_3db: Math.sqrt(0.5), balance_6db: 0.5 }.freeze
  acid_pan_matrix = ->(pan, law) {
    x = pan.to_f.clamp(-1.0, 1.0)
    if %i[constant_power film].include?(law)
      a = (x + 1) * Math::PI / 4
      next [Math.cos(a), 0.0, 0.0, Math.sin(a)]
    end
    if law == :add_channels
      next x >= 0 ? [1 - x, 0.0, x, 1.0] : [1.0, -x, 0.0, 1 + x]
    end
    g = acid_balance.fetch(law, 1.0)
    near = g + (1 - g) * x.abs
    far = g * (1 - x.abs)
    x >= 0 ? [far, 0.0, 0.0, near] : [near, 0.0, 0.0, far]
  }

  acid_laws = %i[constant_power balance_0db balance_3db balance_6db add_channels]
  positions = [-1.5, -1, -0.75, -0.5, -0.1, 0, 0.2, 0.5, 0.9, 1, 3]

  # The laws written out from their definitions (x clamped to -1..1, + is
  # right), each as [[L to L, R to L], [L to R, R to R]].
  written = {
    constant_power: ->(x) { [[Math.cos((x + 1) * Math::PI / 4), 0], [0, Math.sin((x + 1) * Math::PI / 4)]] },
    balance_0db: ->(x) { x >= 0 ? [[1 - x, 0], [0, 1]] : [[1, 0], [0, 1 + x]] },
    balance_3db: ->(x) {
      g = 1 / Math.sqrt(2)
      x >= 0 ? [[g * (1 - x), 0], [0, g + (1 - g) * x]] : [[g - (1 - g) * x, 0], [0, g * (1 + x)]]
    },
    balance_6db: ->(x) { [[(1 - x) / 2, 0], [0, (1 + x) / 2]] },
    add_channels: ->(x) { x >= 0 ? [[1 - x, 0], [x, 1]] : [[1, -x], [0, 1 + x]] },
  }

  describe '.stereo' do
    written.each do |law, formula|
      it "gives the written-out #{law} matrix for numbers" do
        positions.each do |x|
          expected = formula.call(x.clamp(-1, 1).to_f)
          got = described_class.stereo(law, x)
          expect(got.flatten).to all(be_a(Numeric))
          expect(got.flatten.zip(expected.flatten).map { |a, b| (a - b).abs }.max).to be < 1e-15, "#{law} at #{x}: #{got} vs #{expected}"
        end
      end
    end

    acid_laws.each do |law|
      it "matches the ACID study's pan_matrix for #{law}, numbers and SFloat positions" do
        positions.each do |x|
          expect(described_class.stereo(law, x).flatten).to eq(acid_pan_matrix.call(x, law)), "#{law} at #{x}"
        end

        xs = Numo::SFloat.linspace(-1.3, 1.3, 261)
        got = described_class.stereo(law, xs).flatten
        ref = xs.to_a.map { |x| acid_pan_matrix.call(x, law) }.transpose
        got.each_with_index do |g, k|
          g = g.is_a?(Numeric) ? Numo::DFloat.new(xs.length).fill(g) : Numo::DFloat.cast(g)
          # (float32 steps vs the study's doubles)
          expect((g - Numo::DFloat.cast(ref[k])).abs.max).to be < 2e-7, "#{law} entry #{k}"
        end
      end
    end

    it 'keeps the center of each law at its level' do
      g3 = Math.sqrt(0.5)
      expect(described_class.stereo(:balance, 0)).to eq([[1, 0], [0, 1]])
      expect(described_class.stereo(:balance_0db, 0)).to eq([[1, 0], [0, 1]])
      expect(described_class.stereo(:add_channels, 0)).to eq([[1, 0], [0, 1]])
      expect(described_class.stereo(:balance_6db, 0)).to eq([[0.5, 0], [0, 0.5]])
      expect(described_class.stereo(:balance_3db, 0).flatten).to eq([g3, 0, 0, g3])
      expect(described_class.stereo(:constant_power, 0).flatten.map { |v| v.round(12) }).to eq([g3, 0, 0, g3].map { |v| v.round(12) })
    end

    it 'adds channels without losing any: L + R is unchanged at every position' do
      described_class::STEREO_LAWS.each { |law| described_class.stereo(law, 0.3) } # (every law builds)
      positions.each do |x|
        (ll, rl), (lr, rr) = described_class.stereo(:add_channels, x)
        expect(ll + lr).to be_within(1e-15).of(1)
        expect(rl + rr).to be_within(1e-15).of(1)
      end
      expect(described_class.stereo(:add_channels, 1)).to eq([[0, 0], [1, 1]])
      expect(described_class.stereo(:add_channels, -1)).to eq([[1, 1], [0, 0]])
    end

    it 'keeps the existing balance as PanLaws.balance on the diagonal' do
      l, r = described_class.balance(0.5)
      expect(described_class.stereo(:balance, 0.5)).to eq([[l, 0], [0, r]])
    end

    it 'gives :balance_6db the mono :linear law on each channel and :constant_power the :equal_power one' do
      xs = Numo::SFloat.linspace(-1, 1, 41)
      l, r = described_class.gains(:linear, xs)
      m = described_class.stereo(:balance_6db, xs)
      expect((m[0][0] - l).abs.max).to be < 1e-7
      expect((m[1][1] - r).abs.max).to be < 1e-7
      expect(described_class.stereo(:constant_power, xs)).to eq([[described_class.gains(:equal_power, xs)[0], 0], [0, described_class.gains(:equal_power, xs)[1]]])
    end

    it 'raises for unknown and mono laws' do
      expect { described_class.stereo(:linear, 0) }.to raise_error(ArgumentError, /stereo pan law :linear/)
      expect { described_class.stereo(:film, 0) }.to raise_error(ArgumentError, /add_channels/)
    end
  end

  describe 'in ChannelMixer::Balance' do
    def frame(bundle)
      bundle.to_a.map { |o| o.sample(4)[0].round(6) }
    end

    let(:input) { MB::Sound.stereo(0.25.constant, 1.constant) }

    (written.keys + [:balance]).each do |law|
      it "mixes a stereo input by the #{law} matrix at fixed and moving positions" do
        [-0.6, 0, 0.35, 1].each do |x|
          m = described_class.stereo(law, x)
          expected = m.map { |row| (row[0] * 0.25 + row[1]).round(6) }
          expect(frame(input.balance(x, law: law))).to eq(expected)
          expect(frame(input.balance(x.constant, law: law))).to eq(expected)
        end
      end
    end

    it 'is picked by balance(law:) and by pan(law:) on stereo bundles' do
      expect(frame(input.balance(0.5, law: :add_channels))).to eq([0.125, 1.125])
      expect(frame(input.pan(0.5, law: :add_channels))).to eq([0.125, 1.125])
      expect(frame(input.balance(-1, law: :add_channels))).to eq([1.25, 0])
      expect(frame(input.pan(0.5, law: :balance_3db))).to eq(frame(input.balance(0.5, law: :balance_3db)))
      expect(input.balance(0.5, law: :balance_3db).to_a[0].to_s).to start_with('Balance (law: balance_3db, position: 0.5)')
    end

    it 'balances multi-output nodes with a law (GraphNode#balance and #pan pass law:)' do
      file = MB::Sound.file_input('spec/test_data/arp_a7.flac')
      expect(file.balance(0.5, law: :add_channels).to_a[0].to_s).to start_with('Balance (law: add_channels')
      expect(file.pan(0.5, law: :constant_power).to_a[0].to_s).to start_with('Balance (law: constant_power')
    ensure
      file&.close
    end

    it 'keeps mono laws on stereo pans as the default balance (today\'s behavior)' do
      expect(frame(input.pan(0.5, law: :linear))).to eq(frame(input.balance(0.5)))
      expect(frame(input.pan(0.5))).to eq(frame(input.balance(0.5)))
    end

    it 'rejects stereo laws on mono pans and unknown laws, with the choices' do
      expect { 1.constant.pan(0.2, law: :add_channels) }.to raise_error(ArgumentError, /stereo inputs.*:equal_power/)
      expect { input.pan(0.2, law: :sideways) }.to raise_error(ArgumentError, /:linear.*:add_channels/)
      expect { input.balance(0.2, law: :balance3db) }.to raise_error(ArgumentError, /law.*balance_3db/)
    end
  end
end
