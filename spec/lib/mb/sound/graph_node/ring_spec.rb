# Sums that ring until every input ends (GraphNode#ring, Mixer.with_ring,
# Session#ring, render(ring: :all); panel Kaede #4: a gong cut when the
# click under it ended).
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
    out.reduce(:concatenate)
  end

  it 'ends a sum with its first input by default, and with its last after #ring' do
    alone = run(gong.())
    expect(run(gong.() + click.()).length).to be < alone.length / 5
    rung = run((gong.() + click.()).ring)
    expect(rung.length).to eq(alone.length)
    expect(rung[48000..]).to eq(alone[48000..]) # the click is over: the gong alone, exactly
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

  it 'applies to sums made in Mixer.with_ring blocks' do
    s = MB::Sound::GraphNode::Mixer.with_ring(:all) { click.() + gong.() }
    expect(s).not_to be_stop_early
    expect(MB::Sound::GraphNode::Mixer.ring_mode).to eq(:first)
    expect(run(s).length).to eq(run(gong.()).length)
  end

  it 'refuses other modes and other nodes' do
    expect { (gong.() + click.()).ring(:last) }.to raise_error(ArgumentError, /ring is :all .* or :first/)
    expect { 110.hz.sine.ring }.to raise_error(ArgumentError, /applies to sums \(a \+ b\)/)
    expect { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false).tap { |s| s.ring = :most } }
      .to raise_error(ArgumentError, /ring is :all/)
  end

  it 'prints itself back' do
    expect((gong.() + click.()).ring.to_ruby).to end_with('.ring')
  end

  describe 'render(ring: :all)' do
    def song
      MB::Sound.bpm 120
      MB::Sound.bg(:a, gong.() + click.(), fade: 0)
      MB::Sound.at_bar(2) { MB::Sound.bg(:b, click.() + gong.(), fade: 0) }
      set = MB::Sound::Session.current.arrangement
      set.track(:t) { |c| c.tone.sine * c.env(0.001, 0.05, 0, 0.01) + gong.() }
      set.scene(:s, t: MB::Sound.seq(MB::Sound::C5).n16)
      MB::Sound.at_bar(3) { MB::Sound.go :s, on: :now }
    end

    def render(**opts)
      path = tmp_path('ring.flac')
      MB::Sound.render(path, overwrite: true, gain: 1, **opts) { song }
      MB::Sound.rewind
      MB::Sound.read(path)[0]
    end

    it 'lets the sums in the block, scheduled blocks, and track patches ring' do
      plain = render
      rung = render(ring: :all)
      bar = 96000
      # Bar 1: the gong rings past its click; so does bar 2's, and the patch's at bar 3
      [0, bar, 2 * bar].each do |start|
        expect(rung[(start + 24000)...(start + 48000)].abs.max).to be > 0.05
        expect(plain.length <= start + 24000 || plain[(start + 24000)...[start + 48000, plain.length].min].abs.max < 1e-6).to eq(true)
      end
      expect(rung.length).to be > plain.length
    end

    it 'is the same at other buffer sizes' do
      ref = render(ring: :all)
      out = render(ring: :all, buffer_size: 367)
      n = [out.length, ref.length].min
      expect(n).to be > 3 * 96000
      expect(out[0...n]).to eq(ref[0...n])
    end
  end
end
