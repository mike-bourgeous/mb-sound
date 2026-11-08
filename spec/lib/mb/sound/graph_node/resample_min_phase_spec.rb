# The :min_phase resampling mode (fix-bus-resample-1): a causal polyphase
# resampler with a minimum-phase lowpass, which reads nothing ahead, for
# live bus and master chains (spec/lib/mb/sound/graph_node/read_ahead_spec.rb
# checks those).
RSpec.describe(MB::Sound::GraphNode::Resample::MinPhase) do
  # Renders +input+ (an SFloat at 48 kHz) through +chain+ in reads of +size+.
  def render(input, size: 800, frames: input.length, &chain)
    node = chain.(MB::Sound::ArrayInput.new(data: [input], sample_rate: 48000))
    out = []
    got = 0
    while got < frames
      d = node.sample([size, frames - got].min)
      break if d.nil?

      out << d.dup
      got += d.length
    end
    SpecBuffers.join(out)
  end

  let(:pair) { ->(s) { s.resample(96000, mode: :min_phase).resample(48000, mode: :min_phase) } }
  let(:impulse) { Numo::SFloat.zeros(16384).tap { |d| d[4096] = 1 } }

  it 'builds a table that sums to one per input frame' do
    t = described_class.table
    expect(t.length).to eq(described_class::TAPS * described_class::PHASES + 1)
    expect(t[-1]).to eq(0)
    expect(t.sum / described_class::PHASES).to be_within(1e-9).of(1)
  end

  it 'is causal: nothing comes out before the input' do
    out = render(impulse, &pair)
    expect(out[0...4096].abs.max).to eq(0)
    expect(out[4096..].abs.max).to be > 0.3
  end

  it 'is flat within 0.1 dB to 21 kHz, delays low frequencies by under 8 frames, and leaves images 100 dB down' do
    h = Numo::DFloat.cast(render(impulse, &pair))
    spec = Numo::Pocketfft.rfft(h)
    n = h.length
    bin = ->(f) { (f * n / 48000.0).round }
    [100, 1000, 10000, 18000, 21000].each do |f|
      expect(20 * Math.log10(spec[bin.(f)].abs)).to be_within(0.1).of(0), "#{f} Hz"
    end
    k = bin.(1000)
    dphi = Math.atan2(spec[k + 1].imag, spec[k + 1].real) - Math.atan2(spec[k].imag, spec[k].real)
    dphi -= 2 * Math::PI while dphi > Math::PI
    dphi += 2 * Math::PI while dphi < -Math::PI
    delay = -dphi / (2 * Math::PI / n) - 4096
    expect(delay).to be_between(1, 8)

    up = Numo::DFloat.cast(render(impulse, frames: impulse.length * 2) { |s| s.resample(96000, mode: :min_phase) })
    su = Numo::Pocketfft.rfft(up)
    nu = up.length
    image = su[(25000 * nu / 96000)..(47000 * nu / 96000)].abs.max
    expect(20 * Math.log10(image / su[1000 * nu / 96000].abs)).to be < -100
  end

  it 'gives the same samples at any read size, and its C kernel matches the Ruby mirror' do
    noise = Numo::SFloat.new(9000).rand(-1, 1)
    ref = render(noise, size: 800, &pair)
    [[367], [1], [128]].each do |(size)|
      expect(render(noise, size: size, frames: 2000, &pair)).to eq(ref[0...2000])
    end
    odd = ->(s) { s.resample(44100, mode: :min_phase).resample(48000, mode: :min_phase) }
    a = render(noise, size: 800, &odd)
    expect(render(noise, size: 333, &odd)).to eq(a)
    expect(MB::Sound::Kernels.with(:ruby) { render(noise, size: 800, frames: 1600, &odd) }).to eq(a[0...1600])
    expect(MB::Sound::Kernels.with(:check) { render(noise, size: 800, frames: 1600, &pair) }).to eq(ref[0...1600])
  end

  it 'reads only the input its output covers' do
    reads = []
    src = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(48000).rand(-1, 1)], sample_rate: 48000)
    src.singleton_class.prepend(Module.new { define_method(:sample) { |n| reads << n; super(n) } })
    node = src.resample(96000, mode: :min_phase)
    5.times { node.sample(800) }
    expect(reads.sum).to eq(2000) # (output frames 0..3999 at 96 kHz cover input frames 0..1999)
    expect(node.read_ahead).to eq(0)
  end

  it 'ends with a short read, then nil, when its upstream ends' do
    node = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(1000)], sample_rate: 48000).resample(96000, mode: :min_phase)
    lens = []
    while (d = node.sample(800))
      lens << d.length
    end
    expect(lens).to eq([800, 800, 400])
  end
end
