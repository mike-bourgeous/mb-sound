RSpec.describe(MB::Sound::Shaper) do
  let(:sine) { (Numo::SFloat.new(2400).seq * (2 * Math::PI * 1234.5 / 48000)).map { |x| Math.sin(x) } }

  # Non-harmonic power below 20 kHz relative to harmonic power (dB), with
  # coherent sampling at bin +k+.
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

  describe 'C and Ruby versions' do
    {
      'softclip' => [:softclip, 0.25, 1.0, 4],
      'softclip with no linear range' => [:softclip, 0.0, 1.0, 2],
      'hard softclip (limit = threshold)' => [:softclip, 0.5, 0.5, 2],
      'clip' => [:clip, -1.0, 0.5, 2],
      'one-sided clip' => [:clip, 0.0, Float::INFINITY, 1],
      'abs' => [:abs, 0.0, 0.0, 1],
      'quantize' => [:quantize, 0.25, 0.0, 1],
      'hot clip' => [:clip, -0.9, 0.9, 5],
      'hot softclip' => [:softclip, 0.5, 0.9, 5],
      'hot abs' => [:abs, 0.0, 0.0, 5],
    }.each do |name, (mode, p1, p2, amp)|
      [true, false].each do |aa|
        it "give identical samples for #{name}#{aa ? ' with ADAA' : ''}" do
          s1 = [0.0, 0.0, 0.0, 0]
          s2 = [0.0, 0.0, 0.0, 0]
          [0...800, 800...801, 801...2400].each do |r|
            input = sine[r] * amp
            c = MB::Sound::FastClip.shape(input.dup, mode, p1, p2, aa, s1)
            ruby = MB::Sound::Shaper.shape_ruby(input.dup, mode, p1, p2, aa, s2)
            expect(c).to eq(ruby)
          end
        end
      end
    end
  end

  describe 'antialiasing' do
    [
      ['softclip', ->(s) { s.at(4).softclip }, ->(s) { s.at(4).asoftclip }],
      ['clip', ->(s) { s.at(2).clip(-1, 1) }, ->(s) { s.at(2).aclip(-1, 1) }],
      ['abs', ->(s) { s.abs }, ->(s) { s.aabs }],
      ['quantize', ->(s) { s.quantize(0.25) }, ->(s) { s.aquantize(0.25) }],
    ].each do |name, clean, naive|
      it "reduces aliasing of #{name} by at least 8 dB at 3 kHz" do
        k = 1025
        f = k * 48000.0 / 16384
        expect(alias_db(clean.call(f.hz.sine), k)).to be < alias_db(naive.call(f.hz.sine), k) - 8
      end
    end

    it 'leaves the unclipped signal flat in level' do
      [1000, 10000, 16000].each do |f|
        node = f.hz.sine.at(0.2).softclip
        node.sample(4800)
        data = node.sample(48000)
        rms = Math.sqrt((data**2).mean)
        expect(20 * Math.log10(rms / (0.2 / Math.sqrt(2)))).to be_within(0.05).of(0), "#{f} Hz"
      end
    end

    it 'delays by about half a sample' do
      data = 100.hz.sine.at(0.2).softclip.sample(4800)
      expected = 100.hz.sine.at(0.2).with_phase(-100 * 0.5 / 48000.0).sample(4800)
      expect(data[100..]).to all_be_within(1e-4).of_array(expected[100..])
    end
  end

  # fix-clip-overshoot (2026-11-10): the allpass's high band passed at full
  # level through the flat parts, so noise at 5 into clip(-0.9, 0.9) peaked
  # at 4.66.  It is now scaled by the shaper's mean slope and the output
  # limited to the shaper's range.
  describe 'bounded output' do
    def hot_inputs
      MB::Sound.seed(7)
      steps = Numo::SFloat.zeros(2400)
      steps[true] = (Numo::SFloat.new(2400).seq / 37).floor.map { |v| v.to_i.even? ? 5 : -5 }
      [400, 401, 1203, 2000].each { |i| steps[i] = i.odd? ? 10 : -10 }
      {
        'noise at 5' => Numo::SFloat.cast(MB::Sound.noise.at(5).multi_sample(800, 3)),
        'hot saw' => Numo::SFloat.cast(110.hz.ramp.at(5).multi_sample(800, 3)),
        'step jumps and spikes' => steps,
        'full-scale noise' => Numo::SFloat.cast(MB::Sound.noise.multi_sample(800, 3)),
      }
    end

    bounded_shapers = {
      'clip(-0.9, 0.9)' => [:clip, -0.9, 0.9, -0.9, 0.9],
      'clip(-0.2, 0.7)' => [:clip, -0.2, 0.7, -0.2, 0.7],
      'softclip(0.5, 0.9)' => [:softclip, 0.5, 0.9, -0.9, 0.9],
      'softclip(0, 1)' => [:softclip, 0.0, 1.0, -1.0, 1.0],
      'abs' => [:abs, 0.0, 0.0, 0.0, Float::INFINITY],
    }.freeze

    bounded_shapers.each do |name, (mode, p1, p2, lo, hi)|
      it "keeps #{name} within its range for bright, hot input (C and Ruby, any buffer split)" do
        hot_inputs.each do |input_name, input|
          sc = [0.0, 0.0, 0.0, 0]
          sr = [0.0, 0.0, 0.0, 0]
          out = [0...1, 1...129, 129...929, 929...input.length].map { |r|
            c = MB::Sound::FastClip.shape(input[r].dup, mode, p1, p2, true, sc)
            ruby = MB::Sound::Shaper.shape_ruby(input[r].dup, mode, p1, p2, true, sr)
            expect(c).to eq(ruby), "#{input_name}: C and Ruby differ"
            c.dup
          }
          out = SpecBuffers.join(out)
          # (the limits as float32 samples)
          expect(out.min).to be >= Numo::SFloat[lo][0], "#{input_name}: min #{out.min}"
          expect(out.max).to be <= Numo::SFloat[hi][0], "#{input_name}: max #{out.max}"
        end
      end
    end

    it 'holds a signal past the clip level exactly at the level, without its high band' do
      MB::Sound.seed(3)
      input = Numo::SFloat.cast(MB::Sound.noise.at(0.5).multi_sample(800, 1)) + 5
      out = MB::Sound::FastClip.shape(input.dup, :clip, -0.9, 0.9, true, [0.0, 0.0, 0.0, 0])
      expect(out.to_a.uniq).to eq(Numo::SFloat[0.9].to_a)
      out = MB::Sound::FastClip.shape(-input, :clip, -0.9, 0.9, true, [0.0, 0.0, 0.0, 0])
      expect(out.to_a.uniq).to eq(Numo::SFloat[-0.9].to_a)
    end

    it 'keeps the GraphNode methods in range with plans on and off' do
      old = MB::Sound::Plan.enabled
      [true, false].each do |planned|
        MB::Sound::Plan.enabled = planned
        MB::Sound.seed(5)
        nodes = [
          MB::Sound.noise.at(5).clip(-0.9, 0.9),
          MB::Sound.noise.at(5).softclip(0.5, 0.9),
          110.hz.ramp.at(5).clip(-0.9, 0.9),
        ]
        nodes.each do |node|
          MB::Sound::Plan.install(node) if planned
          out = SpecBuffers.join(4.times.map { node.sample(600).dup })
          expect(out.abs.max).to be <= Numo::SFloat[0.9][0], "#{node} (#{planned ? 'planned' : 'unplanned'}): #{out.abs.max}"
        end
      end
    ensure
      MB::Sound::Plan.enabled = old
    end

    it 'keeps the high band where the shaper is linear (the old samples for unclipped input)' do
      input = sine * 0.2
      out = MB::Sound::FastClip.shape(input.dup, :softclip, 0.25, 1.0, true, [0.0, 0.0, 0.0, 0])
      ap_x1 = ap_y1 = input[0].to_f
      expected = input.to_a.map { |x|
        dry = MB::Sound::Shaper::ALLPASS * x + ap_x1 - MB::Sound::Shaper::ALLPASS * ap_y1
        ap_x1 = x
        ap_y1 = dry
        dry
      }
      expect(out).to eq(Numo::SFloat.cast(expected))
    end
  end

  describe 'naive shapers' do
    it 'match the plain functions exactly' do
      data = MB::Sound::ArrayInput.new(data: [Numo::SFloat[-3, -0.6, -0.2, 0, 0.3, 0.9, 2]])
      expect(data.dup.aclip(-0.5, 0.5).sample(7)).to eq(Numo::SFloat[-0.5, -0.5, -0.2, 0, 0.3, 0.5, 0.5])
      expect(data.dup.aabs.sample(7)).to eq(Numo::SFloat[3, 0.6, 0.2, 0, 0.3, 0.9, 2])
      expected = MB::Sound::SoftestClip.new(threshold: 0.25, limit: 1).process(Numo::SFloat[-3, -0.6, -0.2, 0, 0.3, 0.9, 2])
      expect(data.dup.asoftclip.sample(7)).to all_be_within(1e-6).of_array(expected)
    end
  end

  describe 'GraphNode::Shaper' do
    it 'handles complex input with the plain shaper' do
      c = MB::Sound::ArrayInput.new(data: [Numo::SComplex[3 + 4i, 0.1i]])
      expect(c.dup.abs.sample(2)).to eq(Numo::SFloat[5, 0.1])
      expect(c.dup.softclip.sample(2)[0].abs).to be < 1
      expect(c.dup.quantize(0.5).sample(2)).to eq(Numo::SComplex[3 + 4i, 0])
    end

    it 'reads a param or knob given as a setting once, while building (hand-tune-1)' do
      t = 0.3.constant
      x = MB::Sound::ArrayInput.new(data: [sine * 2])
      y = MB::Sound::ArrayInput.new(data: [sine * 2])
      expect(x.softclip(t, 1.0.constant).sample(2400)).to eq(y.softclip(0.3, 1.0).sample(2400))
      expect(t.build_read?).to eq(true)
      expect { 1.constant.softclip(1.hz.lfo) }.to raise_error(ArgumentError, /read while the graph builds/)
    end

    it 'checks its parameters' do
      expect { 1.constant.softclip(0.5, 0.25) }.to raise_error(ArgumentError, /Limit/)
      expect { 1.constant.clip(1, -1) }.to raise_error(ArgumentError, /max/)
    end

    it 'quantizes with a node increment without antialiasing' do
      expect(1.constant.quantize(0.25.constant)).to be_a(MB::Sound::GraphNode::Quantize)
      expect(1.constant.quantize(0)).to be_a(MB::Sound::GraphNode::Quantize)
    end

    it 'names antialiased and naive shapers' do
      expect(1.constant.softclip.to_s).to include('softclip(0.25, 1.0)')
      expect(1.constant.asoftclip.to_s).to include('asoftclip')
    end
  end
end
