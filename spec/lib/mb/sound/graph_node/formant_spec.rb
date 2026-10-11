RSpec.describe(MB::Sound::GraphNode::Formant, :aggregate_failures) do
  let(:klass) { MB::Sound::GraphNode::Formant }

  def collect(node, total, size = 800)
    sizes = Array(size).cycle
    out = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      buf = node.sample(len)
      break if buf.nil?
      out << buf.dup
      n += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  def rms(x)
    Math.sqrt((Numo::DFloat.cast(x) ** 2).mean)
  end

  # Frequencies (Hz) of the local maxima of +node+'s response to +formants+
  # from 100 Hz to 6 kHz, strongest first.
  def peaks(node, formants)
    freqs = Numo::DFloat.linspace(100, 6000, 5901)
    mag = node.response(formants, freqs).abs
    (1...(mag.length - 1)).select { |i| mag[i] > mag[i - 1] && mag[i] >= mag[i + 1] }.sort_by { |i| -mag[i] }.map { |i| freqs[i] }
  end

  describe 'kernel' do
    let(:rng) { Random.new(9) }

    def noise(n, scale = 1.0, offset = 0.0)
      Numo::SFloat.cast(Array.new(n) { (rng.rand - 0.5) * scale + offset })
    end

    # Runs FastFilter.formant and the mirror from the same state and expects
    # identical samples and states.
    def compare(n, x, node, morph, shift, width, normalize: true)
      tables = node.instance_variable_get(:@tables)
      a = Numo::SFloat.zeros(n)
      b = Numo::SFloat.zeros(n)
      sa = Numo::DFloat.cast(noise(10, 0.01))
      sb = sa.dup
      MB::Sound::FastFilter.formant(a, x, tables, morph, shift, width, sa, 48000, normalize)
      klass.process_ruby(b, x, tables, morph, shift, width, sb, 48000, normalize)
      expect(a).to eq(b)
      expect(sa).to eq(sb)
      a
    end

    it 'matches the Ruby mirror with constant and moving settings' do
      one = 110.hz.ramp.formant(:a)
      three = 110.hz.ramp.formant(:a, :i, :u, voice: :soprano)
      x = noise(1500)
      compare(1500, x, one, 0.0, 0.0, 1.0)
      compare(1500, x, one, noise(1500), noise(1500, 24), noise(1500, 1, 1), normalize: false)
      compare(1500, x, three, noise(1500, 1.4, 0.5), 3.0, 0.7)
      compare(1500, Numo::DFloat.cast(x), three, Numo::DFloat.cast(noise(1500, 1.4, 0.5)), noise(1500, 10), noise(1500, 2, 1))
      compare(10, 0.5, three, 0.3, -2.0, 1.0)
    end

    it 'matches the Ruby mirror for edge-case settings' do
      node = 110.hz.ramp.formant(:a, :o)
      odd = Numo::SFloat.cast([Float::NAN, -1, 2, 0, 0.5, 1, Float::INFINITY] * 30)
      compare(odd.length, noise(odd.length), node, odd, odd * 50, odd)
    end

    it 'raises for bad arguments' do
      node = 110.hz.ramp.formant(:a)
      t = node.instance_variable_get(:@tables)
      out = Numo::SFloat.zeros(4)
      st = Numo::DFloat.zeros(10)
      expect { MB::Sound::FastFilter.formant(out, 0.0, t[0...14], 0, 0, 1, st, 48000, true) }.to raise_error(ArgumentError, /tables/)
      expect { MB::Sound::FastFilter.formant(out, 0.0, t, 0, 0, 1, Numo::DFloat.zeros(9), 48000, true) }.to raise_error(ArgumentError, /state/)
      expect { MB::Sound::FastFilter.formant(out, 0.0, t, 0, 0, 1, st, 0, true) }.to raise_error(ArgumentError, /rate/)
      expect { MB::Sound::FastFilter.formant(out, Numo::SFloat.zeros(3), t, 0, 0, 1, st, 48000, true) }.to raise_error(ArgumentError, /length/)
      expect { MB::Sound::FastFilter.formant(Numo::DFloat.zeros(4), 0.0, t, 0, 0, 1, st, 48000, true) }.to raise_error(ArgumentError, /output/)
    end
  end

  it 'has resonant peaks at the vowel formants' do
    node = 110.hz.ramp.formant(:a, voice: :bass, normalize: false)
    f = klass::VOICES[:bass][:a]
    found = peaks(node, f)
    expect(found.first).to be_within(10).of(600)
    expect(found.min_by { |p| (p - 1040).abs }).to be_within(15).of(1040)

    # Unnormalized, F1's peak gain is 0 dB (the table's level)
    expect(node.response(f, [600]).abs[0]).to be_within(0.15).of(1)
  end

  it 'keeps a saw near its input level when normalized' do
    ref = rms(110.hz.ramp.sample(48000))
    klass::VOICES.each_key do |voice|
      klass::VOWELS.each do |v|
        out = rms(110.hz.ramp.formant(v, voice: voice).sample(48000))
        expect((out / ref).to_db).to be_within(6).of(0), "#{voice} #{v}"
      end
    end
  end

  it 'keeps its level as the width changes' do
    noise = -> { MB::Sound.noise(seed: 1) }
    wide = rms(noise.().formant(:e, width: 2).sample(48000))
    narrow = rms(noise.().formant(:e, width: 0.5).sample(48000))
    expect((narrow / wide).to_db.abs).to be < 1.5
  end

  it 'plays one vowel exactly at the ends of a morph' do
    a = collect(110.hz.ramp.formant(:a), 4800)
    o = collect(110.hz.ramp.formant(:o), 4800)
    expect(collect(110.hz.ramp.formant(:a, :o, morph: 0), 4800)).to eq(a)
    expect(collect(110.hz.ramp.formant(:a, :o, morph: 1), 4800)).to eq(o)
    expect(collect(110.hz.ramp.formant(:a, :o, morph: 5), 4800)).to eq(o)
    expect(collect(110.hz.ramp.formant(:a, :e, :o, morph: 1), 4800)).to eq(o)
  end

  it 'moves its formants by the shift, keeping the Q' do
    up = 110.hz.ramp.formant(:a, voice: :bass, shift: 12, normalize: false)
    f = klass::VOICES[:bass][:a].map { |hz, db, bw| [hz * 2, db, bw * 2] }
    expect(peaks(up, f).first).to be_within(20).of(1200)

    a = collect(110.hz.ramp.formant(:a, shift: 7.semitones), 2000)
    b = collect(110.hz.ramp.formant(:a, shift: 7), 2000)
    expect(a).to eq(b)

    # The shift moves the sound: a 12-semitone shift is the same filter at
    # twice the frequencies (within float32 rounding of the coefficients)
    c = collect(110.hz.ramp.formant(:a, shift: 12), 2000)
    expect(c).not_to eq(collect(110.hz.ramp.formant(:a), 2000))
  end

  it 'gives the same output at any buffer size with moving settings' do
    make = -> { 110.hz.ramp.formant(:a, :e, :i, morph: 0.5.hz.lfo.at(0..1), shift: 0.3.hz.lfo.at(-5..5), width: 0.2.hz.lfo.at(0.5..1.5)) }
    expect(collect(make.(), 9600, [1, 7, 128, 33])).to eq(collect(make.(), 9600, 800))
  end

  it 'takes custom vowels as five triples' do
    custom = [[500, 0, 50], [1500, -6, 80], [2500, -12, 100], [3500, -20, 120], [4500, -30, 150]]
    node = 110.hz.ramp.formant(custom, :a)
    expect(node.table.length).to eq(2)
    expect(collect(node, 1000).abs.max).to be > 0.05
  end

  it 'runs per channel on bundles' do
    out = MB::Sound.stereo(110.hz.ramp, 165.hz.ramp).formant(:a, :o, morph: MB::Sound.channels(0.2, 0.8))
    expect(out).to be_a(MB::Sound::GraphNode::Channels)
    expect(out.outputs.map(&:morph)).to eq([0.2, 0.8])
  end

  it 'ends when its input or a parameter node ends' do
    input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(1000)])
    expect(collect(input.formant(:a), 5000).length).to eq(1000)

    morph = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(300)])
    expect(collect(110.hz.ramp.formant(:a, :e, morph: morph), 5000).length).to eq(300)
  end

  it 'rejects bad arguments with helpful messages' do
    expect { 110.hz.ramp.formant(:x) }.to raise_error(ArgumentError, /Unknown vowel/)
    expect { 110.hz.ramp.formant(:a, voice: :baritone) }.to raise_error(ArgumentError, /Unknown voice/)
    expect { 110.hz.ramp.formant([[1, 2]]) }.to raise_error(ArgumentError, /five/)
    expect { 110.hz.ramp.formant(:a, width: 0) }.to raise_error(ArgumentError, /width/)
    expect { 110.hz.ramp.formant(:a, morph: :x) }.to raise_error(ArgumentError, /morph/)
  end

  it 'has the alias vowel, prints itself back as Ruby, and describes itself' do
    a = collect(110.hz.ramp.vowel(:e), 1000)
    expect(collect(110.hz.ramp.formant(:e), 1000)).to eq(a)

    node = 110.hz.ramp.formant(:a, :o, morph: 0.25, voice: :bass, width: 0.8)
    expect(node.to_ruby).to include('formant(:a, :o, morph: 0.25, voice: :bass, width: 0.8)')
    expect(node.to_s).to eq('Formant a>o (bass)')
  end
end
