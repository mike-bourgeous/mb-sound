require 'shellwords'

RSpec.describe('MB::Sound::FastConvolve::Engine', :aggregate_failures) do
  let(:c_engine) { MB::Sound::FastConvolve::Engine }
  let(:ruby_engine) { MB::Sound::Convolution::RubyEngine }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_convolve.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastConvolve::Engine.instance_methods(false).include?(:process)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  def impulse(len, seed)
    rng = Random.new(seed)
    Numo::DFloat[*Array.new(len) { |i| (rng.rand - 0.5) * Math.exp(-i / (len / 3.0)) }]
  end

  def build(klass, partition, nin, nout, paths, irs)
    heads, spectra = MB::Sound::Convolution.prepare(irs, partition)
    klass.new(partition, nin, nout, paths, heads, spectra, irs.map(&:length).max)
  end

  # Runs both engines over the same inputs in the chunks +chunks+ cycles
  # through and returns their outputs.
  def run_both(partition, nin, nout, paths, irs, length, chunks)
    rng = Random.new(7)
    ins = Array.new(nin) { Numo::SFloat[*Array.new(length) { rng.rand - 0.5 }] }
    engines = [build(c_engine, partition, nin, nout, paths, irs), build(ruby_engine, partition, nin, nout, paths, irs)]
    engines.map do |e|
      outs = Array.new(nout) { Numo::SFloat.zeros(length) }
      work = Numo::DComplex.zeros(2 * partition)
      pos = 0
      k = 0
      while pos < length
        n = [chunks[k % chunks.length], length - pos].min
        k += 1
        bufs_in = ins.map { |x| x[pos...(pos + n)].dup }
        bufs_out = Array.new(nout) { Numo::SFloat.zeros(n) }
        MB::Sound::Convolution.run(e, bufs_out, bufs_in, n, work)
        bufs_out.each_with_index { |b, c| outs[c][pos...(pos + n)] = b }
        pos += n
      end
      outs
    end
  end

  {
    'mono' => [1, 1, [[0, 0, 0]], 1],
    'mono to stereo' => [1, 2, [[0, 0, 0], [0, 1, 1]], 2],
    'stereo' => [2, 2, [[0, 0, 0], [1, 1, 1]], 2],
    'true stereo' => [2, 2, [[0, 0, 0], [0, 1, 1], [1, 0, 2], [1, 1, 3]], 4],
  }.each do |name, (nin, nout, paths, nir)|
    it "matches the Ruby mirror within the kernel tolerance (#{name})" do
      [[16, 5], [16, 16], [16, 70], [32, 200]].each do |part, len|
        irs = Array.new(nir) { |c| impulse(len, c + 1) }
        a, b = run_both(part, nin, nout, paths, irs, 300, [7, 16, 1, 33])
        a.zip(b).each do |x, y|
          expect((x - y).abs.max).to be < MB::Sound::Convolution::KERNEL_TOLERANCE, "partition #{part}, impulse #{len}"
          expect(x.abs.max).to be > 0.01
        end
      end
    end
  end

  it 'gives the same samples for any chunking' do
    irs = [impulse(150, 3), impulse(150, 4)]
    base = run_both(32, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 400, [400])[0]
    [[1], [31, 2], [32], [5, 64, 3]].each do |chunks|
      expect(run_both(32, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 400, chunks)[0]).to eq(base), chunks.inspect
    end
  end

  it 'reports silence after the inputs have been quiet for the impulse length, and resets' do
    e = build(c_engine, 16, 1, 1, [[0, 0, 0]], [impulse(40, 1)])
    work = Numo::DComplex.zeros(32)
    out = [Numo::SFloat.zeros(200)]
    MB::Sound::Convolution.run(e, out, [Numo::SFloat.ones(200)], 200, work)
    expect(e.quiet?).to eq(false)
    MB::Sound::Convolution.run(e, out, [nil], 200, work)
    expect(out[0][0...39].abs.max).to be > 0
    expect(out[0][39..].abs.max).to be < 1e-12 # (FFT rounding until the ring holds only silence)
    expect(e.quiet?).to eq(true)
    MB::Sound::Convolution.run(e, out, [nil], 200, work)
    expect(out[0].abs.max).to eq(0)

    MB::Sound::Convolution.run(e, out, [Numo::SFloat.ones(200)], 200, work)
    e.reset
    expect(e.position).to eq([0, 0, 0])
    MB::Sound::Convolution.run(e, out, [nil], 50, work)
    expect(out[0][0...50].abs.max).to eq(0)
  end

  it 'swaps running state with an engine of the same shape' do
    irs = [impulse(64, 2)]
    a = build(c_engine, 16, 1, 1, [[0, 0, 0]], irs)
    b = build(c_engine, 16, 1, 1, [[0, 0, 0]], irs)
    ref = build(c_engine, 16, 1, 1, [[0, 0, 0]], irs)
    work = Numo::DComplex.zeros(32)
    x = Numo::SFloat.new(100).seq.map { |i| Math.sin(i * 0.3) }
    [a, ref].each { |e| MB::Sound::Convolution.run(e, [Numo::SFloat.zeros(100)], [x], 100, work) }
    b.swap_state(a)
    o1 = [Numo::SFloat.zeros(80)]
    o2 = [Numo::SFloat.zeros(80)]
    MB::Sound::Convolution.run(b, o1, [nil], 80, work)
    MB::Sound::Convolution.run(ref, o2, [nil], 80, work)
    expect(o1[0]).to eq(o2[0])
    expect(a.position).to eq([0, 0, 0])

    other = build(c_engine, 32, 1, 1, [[0, 0, 0]], irs)
    expect { a.swap_state(other) }.to raise_error(ArgumentError, /different shapes/)
  end

  it 'checks its arguments' do
    irs = [impulse(64, 2)]
    heads, spectra = MB::Sound::Convolution.prepare(irs, 16)
    expect { c_engine.new(16, 3, 1, [[0, 0, 0]], heads, spectra, 64) }.to raise_error(ArgumentError, /1 or 2 inputs/)
    expect { c_engine.new(16, 1, 1, [[0, 1, 0]], heads, spectra, 64) }.to raise_error(ArgumentError, /out of range/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], Numo::SFloat.zeros(16), spectra, 64) }.to raise_error(ArgumentError, /DFloat/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], heads, spectra[0...10].dup, 64) }.to raise_error(ArgumentError, /bins/)

    e = c_engine.new(16, 1, 1, [[0, 0, 0]], heads, spectra, 64)
    expect { e.process([Numo::SFloat.zeros(20)], [nil], 0, 17) }.to raise_error(ArgumentError, /left in the block/)
    expect { e.process([Numo::SFloat.zeros(4)], [nil], 0, 8) }.to raise_error(ArgumentError, /too short/)
    expect { e.process([Numo::DFloat.zeros(8)], [nil], 0, 8) }.to raise_error(ArgumentError, /SFloat/)
    expect { e.process([Numo::SFloat.zeros(8).freeze], [nil], 0, 8) }.to raise_error(FrozenError)
    expect { e.fft_input(Numo::DComplex.zeros(32)) }.to raise_error(RuntimeError, /block boundary/)
    expect { c_engine.allocate.room }.to raise_error(RuntimeError, /not initialized/)
  end
end
