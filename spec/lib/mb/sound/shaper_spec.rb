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
      expected = 100.hz.sine.at(0.2).with_phase(-2 * Math::PI * 100 * 0.5 / 48000).sample(4800)
      expect(data[100..]).to all_be_within(1e-4).of_array(expected[100..])
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
