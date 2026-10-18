# Sums ring until every input ends (the default since omnibus8; panel Kaede
# #4: a gong cut when the click under it ended), or end with their first
# (GraphNode#ring(:first), Mixer.with_ring(:first), Session#ring,
# render(ring: :first)).
RSpec.describe('ring: :all') do
  after { MB::Sound.rewind }

  # A 2 s gong and a 0.1 s click (one-shot envelopes: they end).
  let(:gong) { -> { 110.hz.sine * MB::Sound.env([[1, 0.001], [0, 2.0, 30]]) } }
  let(:click) { -> { 2000.hz.sine * MB::Sound.env([[1, 0.001], [0, 0.1, 30]]) } }

  # The whole output of +node+ in buffers of +size+.
  def run(node, size = 800)
    out = []
    while (b = node.sample(size)) && !b.empty?
      out << b.dup
      raise 'never ended' if out.length > 100_000
    end
    SpecBuffers.join(out)
  end

  it 'rings a sum until its last input ends by default, and ends with its first after ring(:first)' do
    alone = run(gong.())
    rung = run(gong.() + click.())
    expect(rung.length).to eq(alone.length)
    expect(rung[48000..]).to eq(alone[48000..]) # the click is over: the gong alone, exactly
    expect(run((gong.() + click.()).ring).length).to eq(alone.length)
    expect(run((gong.() + click.()).ring(:first)).length).to be < alone.length / 5
    expect(run((gong.() + click.()).ring(false)).length).to be < alone.length / 5
  end

  it 'covers the sums directly inside (a + b + c), and ring(:first) puts them back' do
    expect(run((click.() + gong.() + click.()).ring).length).to eq(run(gong.()).length)
    s = (click.() + gong.()).ring
    expect(s.ring(:first)).to equal(s)
    expect(run(s).length).to eq(run(click.()).length)
  end

  it 'gives the same samples at any buffer size, ending where its last input ends at that size' do
    ref = run((gong.() + click.()).ring, 800)
    [7, 128, 367].each do |size|
      out = run((gong.() + click.()).ring, size)
      expect(out.length).to eq(run(gong.(), size).length), "#{size}-sample buffers" # (a one-shot envelope ends on its buffer)
      n = [out.length, ref.length].min
      expect(out[0...n]).to eq(ref[0...n]), "#{size}-sample buffers"
    end
  end

  it 'ends sums made in Mixer.with_ring(:first) blocks with their first input' do
    s = MB::Sound::GraphNode::Mixer.with_ring(:first) { click.() + gong.() }
    expect(s).to be_stop_early
    expect(MB::Sound::GraphNode::Mixer.ring_mode).to eq(:all)
    expect(run(s).length).to eq(run(click.()).length)
    expect(MB::Sound::GraphNode::Mixer.with_ring(true) { click.() + gong.() }).not_to be_stop_early
  end

  it 'gives the same samples planned (fused, an ended input dropped) and unplanned' do
    short_gong = -> { 110.hz.sine * MB::Sound.env([[1, 0.001], [0, 0.08, 30]]) }
    short_click = -> { 2000.hz.sine * MB::Sound.env([[1, 0.001], [0, 0.01, 30]]) }
    r = plan_compare(fallbacks: true, check: :raise, sizes: [7, 128, 800, 367, 800, 800, 800, 800, 800]) {
      (short_gong.() + short_click.() * 0.5 + 220.hz.triangle * short_click.()).lp4(3000)
    }
    expect(r.outputs[:unfused].compact.sum(&:length)).to be > 0.08 * 48000
  end

  it 'ends a planned product of a ringing sum when every summand has ended (no 0 * x fold of the ended sum)' do
    short_gong = -> { 110.hz.sine * MB::Sound.env([[1, 0.001], [0, 0.08, 30]]) }
    short_click = -> { 2000.hz.sine * MB::Sound.env([[1, 0.001], [0, 0.01, 30]]) }
    r = plan_compare(fallbacks: true, sizes: [800] * 40) { (short_gong.() + short_click.()) * 3 }
    expect(r.outputs[:unfused].last).to be_nil
    expect(r.outputs[:c].last).to be_nil
  end

  it 'refuses other modes and other nodes' do
    expect { (gong.() + click.()).ring(:last) }.to raise_error(ArgumentError, /ring is :all .* or :first/)
    expect { MB::Sound::GraphNode::Mixer.with_ring(:most) {} }.to raise_error(ArgumentError, /ring is :all/)
    expect { 110.hz.sine.ring }.to raise_error(ArgumentError, /applies to sums \(a \+ b\)/)
    expect { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false).tap { |s| s.ring = :most } }
      .to raise_error(ArgumentError, /ring is :all/)
  end

  it 'prints itself back' do
    expect((gong.() + click.()).ring(:first).to_ruby).to end_with('.ring(:first)')
  end

  describe 'render(ring:)' do
    def song
      MB::Sound.bpm 120
      MB::Sound.bg(:a, gong.() + click.(), fade: 0)
      MB::Sound.at_bar(2) { MB::Sound.bg(:b, click.() + gong.(), fade: 0) }
      set = MB::Sound::Session.current.arrangement
      set.track(:t) { |c| c.tone.sine * c.env(0.001, 0.05, 0, 0.01) + gong.() }
      set.scene(:s, t: MB::Sound.seq(MB::Sound::C5).n16)
      MB::Sound.at_bar(3) { MB::Sound.go :s, on: :now }
    end

    # (rendered at -12 dB and scaled back: the gongs and clicks add up to
    # +6 dBFS, which the FLAC would clip)
    def render(**opts)
      path = tmp_path('ring.flac')
      MB::Sound.render(path, overwrite: true, gain: 0.25, **opts) { song }
      MB::Sound.rewind
      MB::Sound.read(path)[0] * 4
    end

    it 'lets the sums in the block, scheduled blocks, and track patches ring (or end with ring: :first)' do
      plain = render(ring: :first)
      rung = render
      bar = 96000
      # Bar 1: the gong rings past its click; so does bar 2's, and the patch's at bar 3
      [0, bar, 2 * bar].each do |start|
        expect(rung[(start + 24000)...(start + 48000)].abs.max).to be > 0.05
        expect(plain.length <= start + 24000 || plain[(start + 24000)...[start + 48000, plain.length].min].abs.max < 1e-6).to eq(true)
      end
      expect(rung.length).to be > plain.length
    end

    it 'is the same at other buffer sizes' do
      ref = render
      out = render(buffer_size: 367)
      n = [out.length, ref.length].min
      expect(n).to be > 3 * 96000
      # Within the plan layer's :fast sines (the block where an input ends
      # runs unfused, with libm's sine, at a place that depends on the
      # buffer size)
      expect((out[0...n] - ref[0...n]).abs.max).to be < 1e-6
    end
  end
end
