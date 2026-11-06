require 'fileutils'

RSpec.describe(MB::Sound::GraphNode::Convolver, :aggregate_failures) do
  # Direct convolution in double precision (the reference).
  def direct(x, h)
    x = Numo::DFloat.cast(x)
    h = Numo::DFloat.cast(h)
    y = Numo::DFloat.zeros(x.length + h.length - 1)
    h.length.times { |j| y[j...(j + x.length)] += x * h[j] if h[j] != 0 }
    y
  end

  def pad(a, n)
    z = Numo::DFloat.zeros(n)
    z[0...[a.length, n].min] = a[0...[a.length, n].min]
    z
  end

  def noise(n, seed)
    rng = Random.new(seed)
    Numo::SFloat[*Array.new(n) { rng.rand - 0.5 }]
  end

  def impulse(len, seed, decay: len / 4.0)
    rng = Random.new(seed)
    Numo::DFloat[*Array.new(len) { |i| (rng.rand - 0.5) * Math.exp(-i / decay) }]
  end

  def input(data)
    MB::Sound::ArrayInput.new(data: [data])
  end

  # Every output's samples until all end, at buffer size +bs+.
  def render(node, bs)
    outs = node.respond_to?(:outputs) ? node.outputs : [node]
    res = outs.map { [] }
    loop do
      bufs = outs.map { |o| o.sample(bs) }
      break if bufs.all?(&:nil?)
      bufs.each_with_index { |b, i| res[i] << b.dup if b }
    end
    res.map { |r| Numo::DFloat.cast(r[0].concatenate(*r[1..])) }
  end

  # Peak-relative error in dB.
  def error_db(y, ref)
    n = [y.length, ref.length].max
    20 * Math.log10((pad(y, n) - pad(ref, n)).abs.max / ref.abs.max + 1e-300)
  end

  let(:sizes) { [1, 128, 800, *slow_tier([367, 64])] }

  describe 'against a direct convolution' do
    it 'matches within -140 dB at every buffer size, bit for bit across sizes (mono, short and long impulses)' do
      x = noise(3000, 1)
      [[20, nil], [64, 64], [65, 64], [128, 64], [129, 64], [2000, 128], [9000, nil]].each do |len, part|
        h = impulse(len, len)
        ref = direct(x, h)
        outs = sizes.map { |bs| render(input(x).convolve(h, normalize: false, partition: part), bs)[0] }
        outs.each_with_index do |y, i|
          expect(y.length).to eq(ref.length), "length #{len}, buffer #{sizes[i]}"
          expect(error_db(y, ref)).to be < -140, "length #{len}, partition #{part.inspect}, buffer #{sizes[i]}"
          expect(y).to eq(outs[0]), "length #{len}, buffer #{sizes[i]} vs #{sizes[0]}"
        end
      end
    end

    it 'runs mono to stereo, stereo, and true stereo impulses' do
      xl = noise(1500, 2)
      xr = noise(1200, 3)
      h = Array.new(4) { |c| impulse(900 + 50 * c, 10 + c) }
      n = 1500 + 1050 - 1
      cases = {
        'mono to stereo' => [[xl], h[0..1], [pad(direct(xl, h[0]), n), pad(direct(xl, h[1]), n)]],
        'stereo, one impulse' => [[xl, xr], h[0..0], [direct(xl, h[0]), direct(xr, h[0])]],
        'stereo, two impulses' => [[xl, xr], h[0..1], [direct(xl, h[0]), direct(xr, h[1])]],
        'true stereo' => [[xl, xr], h, [pad(direct(xl, h[0]), n) + pad(direct(xr, h[2]), n), pad(direct(xl, h[1]), n) + pad(direct(xr, h[3]), n)]],
        'mono into true stereo' => [[xl], h, [pad(direct(xl, h[0]), n) + pad(direct(xl, h[2]), n), pad(direct(xl, h[1]), n) + pad(direct(xl, h[3]), n)]],
      }
      cases.each do |name, (xs, irs, refs)|
        outs = [1, 128, 800].map { |bs|
          ins = xs.map { |x| input(x) }
          src = ins.length == 1 ? ins[0] : MB::Sound::GraphNode::Channels.new(ins)
          render(src.convolve(irs, normalize: false, partition: 128), bs)
        }
        outs.each do |ys|
          expect(ys.length).to eq(2), name
          ys.zip(refs).each { |y, r| expect(error_db(y, r)).to be < -140, name }
          expect(ys).to eq(outs[0]), name
        end
      end
    end
  end

  it 'has no latency: a one-sample impulse returns the input from sample 0' do
    x = noise(500, 4)
    [nil, 32].each do |part|
      [1, 128].each do |bs|
        y = render(input(x).convolve(Numo::DFloat[1.0], partition: part), bs)[0]
        expect(y).to eq(Numo::DFloat.cast(x))
      end
    end
    # a long impulse starting with a 1: the first sample is the input's first
    h = impulse(5000, 5)
    h[0] = 1
    y = render(input(x).convolve(h, normalize: false), 1)[0]
    expect(y[0]).to eq(x[0])
  end

  it 'rings for the impulse length after the input ends, and lines up inputs ending at different times' do
    h = impulse(700, 6)
    xl = noise(1000, 7)
    xr = noise(300, 8)
    ys = render(MB::Sound::GraphNode::Channels.new([input(xl), input(xr)]).convolve([h, h], normalize: false), 128)
    expect(ys.map(&:length)).to eq([1699, 1699])
    expect(error_db(ys[1], direct(xr, h))).to be < -140
  end

  describe 'options' do
    let(:x) { noise(2000, 9) }
    let(:h) { impulse(1000, 10) }

    it 'normalizes to unit energy per output by default and applies gain' do
      y = render(input(x).convolve(h), 128)[0]
      ref = direct(x, h / Math.sqrt((h**2).sum))
      expect(error_db(y, ref)).to be < -130
      y6 = render(input(x).convolve(h, gain: -6.db), 128)[0]
      expect((y6 - y * 10**(-0.3)).abs.max).to be < 1e-6
    end

    it 'mixes dry and wet with equal power (mix:), or by wet: and dry: levels' do
      wet = render(input(x).convolve(h), 128)[0]
      mixed = render(input(x).convolve(h, mix: 0.25), 128)[0]
      ref = pad(wet, wet.length) * Math.sqrt(0.25) + pad(Numo::DFloat.cast(x), wet.length) * Math.sqrt(0.75)
      expect((mixed - ref).abs.max).to be < 1e-6
      both = render(input(x).convolve(h, wet: -6.db, dry: 1), 128)[0]
      expect((both - (wet * 10**(-0.3) + pad(Numo::DFloat.cast(x), wet.length))).abs.max).to be < 1e-6
      expect(render(input(x).convolve(h, mix: 0), 128)[0][0...2000]).to eq(Numo::DFloat.cast(x))
    end

    it 'takes a node mix' do
      y = render(input(x).convolve(h, mix: 0.5.constant), 128)[0]
      z = render(input(x).convolve(h, mix: 0.5), 128)[0]
      expect((y - z).abs.max).to be < 1e-6
    end

    it 'delays the impulse by predelay and truncates it with a fade' do
      y = render(input(x).convolve(h, normalize: false, predelay: 100.samples), 128)[0]
      expect(error_db(y, direct(x, pad(Numo::DFloat.zeros(100).concatenate(h), 1100)))).to be < -140
      expect(y[0...100].abs.max).to be < 1e-12 # (FFT rounding)

      t = render(input(x).convolve(h, normalize: false, length: 400.samples, fade: 100.samples), 128)[0]
      hh = h[0...400].dup
      win = (Numo::NMath.cos((Numo::DFloat.new(100).seq(0.5) / 100) * Math::PI) + 1) * 0.5
      hh[300..] = hh[300..] * win
      expect(t.length).to eq(2000 + 399)
      expect(error_db(t, direct(x, hh))).to be < -140
      expect(render(input(x).convolve(h, trim: 400.samples, fade: 100.samples, normalize: false), 128)[0]).to eq(t)
      expect { input(x).convolve(h, length: 1, trim: 1) }.to raise_error(ArgumentError, /not both/)
    end

    it 'raises for impulses it cannot use' do
      expect { input(x).convolve([h, h, h]) }.to raise_error(ArgumentError, /1, 2, or 4 channels/)
      expect { input(x).convolve(Numo::DFloat[1, Float::NAN]) }.to raise_error(ArgumentError, /finite/)
      expect { input(x).convolve(42) }.to raise_error(ArgumentError, /Sample, a file path/)
      expect { MB::Sound::GraphNode::Channels.new([input(x)] * 3).convolve(h) }.to raise_error(ArgumentError, /mono or stereo/)
    end
  end

  describe 'impulses from files' do
    let(:h) { impulse(3000, 11) }
    let(:x) { noise(1000, 12) }

    it 'reads a file path as a Sample (stereo files, other rates resampled)' do
      path = tmp_path('ir.wav')
      MB::Sound.write(path, [h * 0.5, h * -0.25], sample_rate: 48000)
      ys = render(input(x).convolve(path, normalize: false), 128)
      expect(ys.length).to eq(2)
      expect(error_db(ys[0], direct(x, h * 0.5))).to be < -80 # (a 16/24-bit file)
      expect(error_db(ys[1], direct(x, h * -0.25))).to be < -80

      s = MB::Sound::Sample[path]
      expect(render(input(x).convolve(s, normalize: false), 128)).to eq(ys)

      p44 = tmp_path('ir44.wav')
      MB::Sound.write(p44, [MB::Sound::Analysis::DSP.resample(h, 48000, 44100)], sample_rate: 44100)
      y44 = render(input(x).convolve(p44, normalize: false), 128)[0]
      expect(y44.length).to be_within(2).of(x.length + h.length - 1)
    end

    it 'saves and loads a graph naming its impulse file beside the document' do
      dir = File.dirname(tmp_path('docs/x'))
      FileUtils.mkdir_p(dir)
      MB::Sound.write(File.join(dir, 'room.wav'), [h], sample_rate: 48000)
      code = "220.hz.saw.at(0.5).convolve('room.wav', mix: 0.3, length: 0.05)"
      g = MB::Sound::GraphIO.load(code, base_dir: dir)
      expect(g.to_ruby).to include('convolve("room.wav", mix: 0.3, length: 0.05)')
      doc = MB::Sound::GraphIO.dump(g, name: 'conv')
      path = File.join(dir, 'conv.mbg.rb')
      File.write(path, doc)
      loaded = MB::Sound::GraphIO.load(path)
      expect(loaded.to_ruby).to include('convolve("room.wav", mix: 0.3, length: 0.05)')
      a = Array.new(5) { loaded.sample(800).dup }
      b = Array.new(5) { g.sample(800).dup }
      expect(a).to eq(b)
      expect(a.map { |v| v.abs.max }.max).to be > 0.1
    end

    it 'refuses impulse files outside the document' do
      expect { MB::Sound::GraphIO.load("220.hz.saw.convolve('/etc/hostname')") }.to raise_error(MB::Sound::GraphIO::LoadError, /only documents loaded from a file/)
      expect { MB::Sound::GraphIO.load("220.hz.saw.convolve('../x.wav')", base_dir: tmp_path('docs')) }.to raise_error(MB::Sound::GraphIO::LoadError, /relative to the document/)
    end
  end

  describe 'node behavior' do
    it 'may sleep once its input has been silent for the impulse length' do
      h = impulse(300, 13)
      conv = input(noise(200, 14).concatenate(Numo::SFloat.zeros(3000))).convolve(h)
      expect(conv.sleep_ready?).to eq(false)
      conv.sample(400)
      expect(conv.sleep_ready?).to eq(false)
      conv.sample(1600)
      expect(conv.sleep_ready?).to eq(true)
    end

    it 'carries its state into a rebuilt convolver of the same shape' do
      h = impulse(500, 15)
      x = noise(2000, 16)
      ref = render(input(x).convolve(h), 100)[0]

      old = input(x).convolve(h)
      first = Array.new(5) { old.sample(100).dup }
      rest_src = MB::Sound::ArrayInput.new(data: [x[500..].dup])
      fresh = rest_src.convolve(h)
      expect(fresh.carry_fits?(old)).to eq(true)
      fresh.carry_adopt(old)
      rest = render(fresh, 100)[0]
      y = Numo::DFloat.cast(first.inject { |a, b| a.concatenate(b) }).concatenate(rest)
      expect(y).to eq(ref)
      expect(fresh.carry_fits?(input(x).convolve(impulse(5000, 1)))).to eq(false)
    end

    it 'matches the Ruby kernel in check mode' do
      MB::Sound::Kernels.with(:check) do
        render(MB::Sound::GraphNode::Channels.new([input(noise(600, 17)), input(noise(500, 18))]).convolve(Array.new(4) { |c| impulse(200, c) }, partition: 32), 100)
      end
      expect(MB::Sound::Kernels.checked[:convolve_engine]).to be > 0
    end

    it 'prints its impulse file in recipes and reads its options from the catalog' do
      path = tmp_path('r.wav')
      MB::Sound.write(path, [impulse(100, 19)], sample_rate: 48000)
      expect(110.hz.saw.convolve(path, wet: -6.db, dry: 1).to_ruby).to eq("110.hz.saw.convolve(#{path.inspect}, wet: -6.db, dry: 1)")
    end
  end
end
