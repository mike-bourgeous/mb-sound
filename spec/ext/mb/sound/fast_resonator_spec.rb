require 'shellwords'

RSpec.describe('MB::Sound::FastResonator', :aggregate_failures) do
  let(:fast) { MB::Sound::FastResonator }
  let(:mirror) { MB::Sound::GraphNode::Resonator }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_resonator.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastResonator.respond_to?(:ping)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  # Runs the kernel and the mirror on the same inputs from the same state
  # and expects identical samples and states.
  def compare(n, input, freq, decay, state: [0.0, 0.0], rate: 48000, phase: 0.0)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    sa = Numo::DFloat.cast(state)
    sb = Numo::DFloat.cast(state)
    fast.ping(a, input, freq, decay, sa, rate, Math.cos(phase), Math.sin(phase))
    mirror.process_ruby(b, input, freq, decay, sb, rate, Math.cos(phase), Math.sin(phase))
    expect(a).to eq(b), "n=#{n} freq=#{freq.class} decay=#{decay.class}"
    expect(sa).to eq(sb)
    a
  end

  let(:rng) { Random.new(3) }

  def noise(n)
    Numo::SFloat.cast(Array.new(n) { rng.rand - 0.5 })
  end

  it 'matches the Ruby mirror with scalar inputs' do
    impulse = Numo::SFloat.zeros(257)
    impulse[0] = 0.75
    impulse[100] = 1
    compare(257, impulse, 55.0, 24000.0)
    compare(257, impulse, 55.0, 24000.0, phase: Math::PI / 2)
    compare(3, 0.0, 1000.0, 100.0, state: [0.3, -0.4])
  end

  it 'matches the Ruby mirror with moving frequency and decay arrays' do
    [1, 2, 127, 128, 801].each do |n|
      freq = (noise(n) + 0.5) * 9000 + 30
      decay = (noise(n) + 0.5) * 50000 + 10
      compare(n, noise(n), freq, decay, state: [0.1, 0.2])
      compare(n, noise(n), Numo::DFloat.cast(freq), 2000, rate: 44100)
    end
  end

  it 'reads complex inputs by their real parts, like the mirror' do
    x = Numo::SComplex.cast(noise(64)) + 1i
    compare(64, x, 440, 4800)
  end

  it 'treats decays of zero or less as silence after the strike' do
    impulse = Numo::SFloat[1, 0, 0, 0]
    out = compare(4, impulse, 1000, 0, phase: Math::PI / 2)
    expect(out.to_a).to eq([1, 0, 0, 0])
    compare(4, impulse, 1000, -5)
  end

  it 'flushes tiny states to zero' do
    out = compare(2000, 0.0, 100, 10, state: [1e-20, 0.0])
    expect(out[-1]).to eq(0)
  end

  it 'raises for bad buffers' do
    state = Numo::DFloat.zeros(2)
    expect { fast.ping(Numo::DFloat.zeros(4), 0, 1, 1, state, 48000, 1, 0) }.to raise_error(ArgumentError, /SFloat/)
    expect { fast.ping(Numo::SFloat.zeros(4), 0, 1, 1, Numo::DFloat.zeros(3), 48000, 1, 0) }.to raise_error(ArgumentError, /State/)
    expect { fast.ping(Numo::SFloat.zeros(4), Numo::SFloat.zeros(3), 1, 1, state, 48000, 1, 0) }.to raise_error(ArgumentError, /length/)
    expect { fast.ping(Numo::SFloat.zeros(4), 0, 1, 1, state, 0, 1, 0) }.to raise_error(ArgumentError, /rate/)
  end
end
