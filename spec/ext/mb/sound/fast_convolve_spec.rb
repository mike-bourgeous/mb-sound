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

  # A uniform plan of +partition+, or a non-uniform one with a spread level
  # (a head of 64, partitions of 64 to 1024, then of 512 from 1024).
  def plan_for(len, partition)
    return MB::Sound::Convolution.plan(len, partition: partition) if partition.is_a?(Integer)

    levels = [[64, 1, ([len, 1024].min - 64 + 63) / 64]]
    levels << [512, 2, (len - 1024 + 511) / 512] if len > 1024
    MB::Sound::Convolution::Plan.new(head: 64, levels: levels.select { |_, _, k| k > 0 })
  end

  def build(klass, partition, nin, nout, paths, irs)
    MB::Sound::Convolution::Runner.new(irs, inputs: nin, outputs: nout, paths: paths, plan: plan_for(irs.map(&:length).max, partition), kernel: klass)
  end

  # Runs both engines over the same inputs in the chunks +chunks+ cycles
  # through and returns their outputs.
  def run_both(partition, nin, nout, paths, irs, length, chunks, klasses: [c_engine, ruby_engine])
    rng = Random.new(7)
    ins = Array.new(nin) { Numo::SFloat[*Array.new(length) { rng.rand - 0.5 }] }
    klasses.map do |klass|
      runner = build(klass, partition, nin, nout, paths, irs)
      outs = Array.new(nout) { Numo::SFloat.zeros(length) }
      pos = 0
      k = 0
      while pos < length
        n = [chunks[k % chunks.length], length - pos].min
        k += 1
        bufs_in = ins.map { |x| x[pos...(pos + n)].dup }
        bufs_out = Array.new(nout) { Numo::SFloat.zeros(n) }
        runner.run(bufs_out, bufs_in, n)
        bufs_out.each_with_index { |b, c| outs[c][pos...(pos + n)] = b }
        pos += n
      end
      outs
    end
  end

  # Direct convolution (double).
  def direct(x, h)
    y = Numo::DFloat.zeros(x.length + h.length - 1)
    h.length.times { |j| y[j...(j + x.length)] += Numo::DFloat.cast(x) * h[j] if h[j] != 0 }
    y
  end

  {
    'mono' => [1, 1, [[0, 0, 0]], 1],
    'mono to stereo' => [1, 2, [[0, 0, 0], [0, 1, 1]], 2],
    'stereo' => [2, 2, [[0, 0, 0], [1, 1, 1]], 2],
    'true stereo' => [2, 2, [[0, 0, 0], [0, 1, 1], [1, 0, 2], [1, 1, 3]], 4],
  }.each do |name, (nin, nout, paths, nir)|
    it "matches the Ruby mirror within the kernel tolerance, uniform (#{name})" do
      [[16, 5], [16, 16], [16, 70], [32, 200]].each do |part, len|
        irs = Array.new(nir) { |c| impulse(len, c + 1) }
        a, b = run_both(part, nin, nout, paths, irs, 300, [7, 16, 1, 33])
        a.zip(b).each do |x, y|
          expect((x - y).abs.max).to be < MB::Sound::Convolution::KERNEL_TOLERANCE, "partition #{part}, impulse #{len}"
          expect(x.abs.max).to be > 0.01
        end
      end
    end

    it "matches the Ruby mirror and a direct convolution with a spread level (#{name})" do
      len = 2600 # (64-sample partitions to 1024, then 4 spread 512-sample partitions from 1024)
      irs = Array.new(nir) { |c| impulse(len, c + 11) }
      a, b = run_both(:spread, nin, nout, paths, irs, 4200, [100, 1, 512, 37])
      a.zip(b).each { |x, y| expect((x - y).abs.max).to be < MB::Sound::Convolution::KERNEL_TOLERANCE }
      rng = Random.new(7)
      ins = Array.new(nin) { Numo::SFloat[*Array.new(4200) { rng.rand - 0.5 }] }
      paths.group_by { |_, o, _| o }.each do |o, ps|
        ref = ps.map { |i, _, r| direct(ins[i], irs[r])[0...4200] }.sum
        expect((Numo::DFloat.cast(a[o]) - ref).abs.max / ref.abs.max).to be < 1e-6, "output #{o}"
      end
    end
  end

  it 'gives the same samples for any chunking, uniform and with a spread level' do
    irs = [impulse(150, 3), impulse(150, 4)]
    base = run_both(32, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 400, [400], klasses: [c_engine])[0]
    [[1], [31, 2], [32], [5, 64, 3]].each do |chunks|
      expect(run_both(32, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 400, chunks, klasses: [c_engine])[0]).to eq(base), chunks.inspect
    end

    irs = [impulse(3000, 5), impulse(2500, 6)]
    base = run_both(:spread, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 6000, [6000], klasses: [c_engine])[0]
    [[1], [63, 2], [512], [5, 128, 3, 700]].each do |chunks|
      expect(run_both(:spread, 2, 2, [[0, 0, 0], [1, 1, 1]], irs, 6000, chunks, klasses: [c_engine])[0]).to eq(base), chunks.inspect
    end
  end

  it 'plans a 128-tap head, then 128, 1024, and spread 8192-sample partitions' do
    plan = MB::Sound::Convolution.plan(288_000)
    expect(plan.head).to eq(128)
    expect(plan.levels).to eq([[128, 1, 7], [1024, 1, 15], [8192, 2, 34]])
    expect(MB::Sound::Convolution.plan(100).levels).to eq([])
    expect(MB::Sound::Convolution.plan(129).levels).to eq([[128, 1, 1]])
    expect(MB::Sound::Convolution.plan(1025).levels).to eq([[128, 1, 7], [1024, 1, 1]])
    expect(MB::Sound::Convolution.plan(16_384).levels).to eq([[128, 1, 7], [1024, 1, 15]])
    expect(MB::Sound::Convolution.plan(16_385).levels).to eq([[128, 1, 7], [1024, 1, 15], [8192, 2, 1]])
    expect(MB::Sound::Convolution.plan(3000, partition: 512).levels).to eq([[512, 1, 5]])
    expect(plan.to_s).to eq('128 + 7 x 128 + 15 x 1024 + 34 x 8192 (spread)')
  end

  it 'reports silence after the inputs have been quiet long enough, and resets' do
    [16, :spread].each do |plan|
      r = build(c_engine, plan, 1, 1, [[0, 0, 0]], [impulse(plan == 16 ? 40 : 1500, 1)])
      e = r.engine
      n = plan == 16 ? 200 : 5000
      out = [Numo::SFloat.zeros(n)]
      r.run(out, [Numo::SFloat.ones(n)], n)
      expect(e.quiet?).to eq(false)
      r.run(out, [nil], n)
      tail = plan == 16 ? 39 : 1499
      expect(out[0][0...tail].abs.max).to be > 0
      expect(out[0][tail..].abs.max).to be < 1e-12 # (FFT rounding until the ring holds only silence)
      r.run(out, [nil], n) until e.quiet?
      r.run(out, [nil], n)
      expect(out[0].abs.max).to eq(0)

      r.run(out, [Numo::SFloat.ones(n)], n)
      e.reset
      expect(e.position[0]).to eq(0)
      expect(e.position[1].map(&:first).uniq).to eq([0]) unless e.position[1].empty?
      r.run(out, [nil], 50)
      expect(out[0][0...50].abs.max).to eq(0)
    end
  end

  it 'swaps running state with an engine of the same shape' do
    [16, :spread].each do |plan|
      irs = [impulse(plan == 16 ? 64 : 2000, 2)]
      a, b, ref = Array.new(3) { build(c_engine, plan, 1, 1, [[0, 0, 0]], irs) }
      x = Numo::SFloat.new(1700).seq.map { |i| Math.sin(i * 0.3) }
      [a, ref].each { |r| r.run([Numo::SFloat.zeros(1700)], [x], 1700) }
      b.engine.swap_state(a.engine)
      o1 = [Numo::SFloat.zeros(2500)]
      o2 = [Numo::SFloat.zeros(2500)]
      b.run(o1, [nil], 2500)
      ref.run(o2, [nil], 2500)
      expect(o1[0]).to eq(o2[0])
      expect(o1[0].abs.max).to be > 0
      expect(a.engine.position[0]).to eq(0)
    end

    other = build(c_engine, 32, 1, 1, [[0, 0, 0]], [impulse(64, 2)])
    expect { build(c_engine, 16, 1, 1, [[0, 0, 0]], [impulse(64, 2)]).engine.swap_state(other.engine) }.to raise_error(ArgumentError, /different shapes/)
  end

  it 'checks its arguments' do
    irs = [impulse(64, 2)]
    head, levels = MB::Sound::Convolution.prepare(irs, MB::Sound::Convolution.plan(64, partition: 16))
    expect { c_engine.new(16, 3, 1, [[0, 0, 0]], head, levels, 64) }.to raise_error(ArgumentError, /1 or 2 inputs/)
    expect { c_engine.new(16, 1, 1, [[0, 1, 0]], head, levels, 64) }.to raise_error(ArgumentError, /out of range/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], Numo::SFloat.zeros(16), levels, 64) }.to raise_error(ArgumentError, /DFloat/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], head, [[16, 1, levels[0][2][0...10].dup]], 64) }.to raise_error(ArgumentError, /bins/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], head, [[16, 2, levels[0][2]]], 64) }.to raise_error(ArgumentError, /spread/)
    expect { c_engine.new(16, 1, 1, [[0, 0, 0]], head, [[24, 1, Numo::DComplex.zeros(25)]], 64) }.to raise_error(ArgumentError, /multiple of the head/)

    e = c_engine.new(16, 1, 1, [[0, 0, 0]], head, levels, 64)
    expect { e.process([Numo::SFloat.zeros(20)], [nil], 0, 17) }.to raise_error(ArgumentError, /left in the block/)
    expect { e.process([Numo::SFloat.zeros(4)], [nil], 0, 8) }.to raise_error(ArgumentError, /too short/)
    expect { e.process([Numo::DFloat.zeros(8)], [nil], 0, 8) }.to raise_error(ArgumentError, /SFloat/)
    expect { e.process([Numo::SFloat.zeros(8).freeze], [nil], 0, 8) }.to raise_error(FrozenError)
    expect { e.fft_input(0, Numo::DComplex.zeros(32)) }.to raise_error(RuntimeError, /block boundary/)
    expect(e.task(Numo::DComplex.zeros(4))).to eq(0) # (no spread level)
    expect { e.task_result(Numo::DComplex.zeros(4)) }.to raise_error(RuntimeError, /No sub-FFT/)
    expect { c_engine.allocate.room }.to raise_error(RuntimeError, /not initialized/)
  end
end
