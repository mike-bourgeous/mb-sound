RSpec.describe(MB::Sound::Playable) do
  let(:arp) { MB::Sound::Sample['spec/test_data/arp_a7.flac'] }

  def new_session
    MB::Sound::Session.new(
      output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    )
  end

  # The first +frames+ of +sound+ played with Session#add in a headless
  # Session (master gain 1), as one Array of channels.
  def session_render(sound = nil, frames: 48000, seed: 1)
    session = new_session
    session.master_gain = 1
    MB::Sound.seed(seed)
    session.add(sound || yield, on: :now)
    Array.new(frames / 800) { session.process_buffer(800).map(&:dup) }.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }
  ensure
    session&.close
  end

  describe '.graph' do
    it 'describes things and says whether they end' do
      expect(described_class.graph(arp)).to have_attributes(ends: true, description: /arp_a7/)
      expect(described_class.graph(arp.node).ends).to eq(nil)
      expect(described_class.graph(MB::Sound.seq(MB::Sound::C4).loop)).to have_attributes(ends: false, note: /soft saw/)
      expect(described_class.graph([arp, 'spec/test_data/arp_a7.flac']).nodes.length).to eq(4)
      expect(described_class.graph(Numo::SFloat.zeros(2, 10)).nodes.length).to eq(2)
    end

    it 'plays slices in order with gaps' do
      g = described_class.graph(arp.slices(2))
      out = Array.new(60) { g.nodes[0].sample(800)&.dup }.compact
      total = out.sum(&:length)
      expect(total).to be >= arp.length + 2 * described_class::SLICE_GAP * 48000 - 800
    end

    it 'plays an instrument covering the keyboard as a phrase in C, a drum-like keymap key by key' do
      expect(described_class.demo_phrase(arp.to_instrument).events.map(&:value).uniq.length).to eq(4)
      keys = described_class.demo_phrase(arp.slices(4).keymap).events.map(&:value)
      expect(keys).to eq((36..43).to_a) # 4 slices, then the same reversed
    end
  end

  describe 'clips that remember their instrument' do
    let(:brk) { arp.slices(8).name(k: 0..1, s: 4..5) }
    let(:chop) { brk.chop(:k, MB::Sound::T, 2, [:s, 2], brk[:s].rev).loop }

    it 'keeps the instrument through transforms' do
      expect(chop.instrument).to equal(brk)
      [chop.transpose(3), chop.reverse, chop.swing(0.2), chop.humanize(0.01), chop | chop, chop.n8, chop.loop(align: :launch)].each do |c|
        expect(c.instrument).to equal(brk)
      end
      expect(MB::Sound.seq(MB::Sound::C4).instrument).to eq(nil)
      expect(chop.played_by(nil).instrument).to eq(nil)
      expect(chop.instrument).to equal(brk) # played_by makes a copy
    end

    it 'chops on another keymap when given from: or spread:' do
      c = brk.chop(0, 1, from: 48)
      expect(c.instrument).to be_a(MB::Sound::Sampler::Instrument)
      expect(c.instrument.regions.first.keys[0]).to eq(48)
    end

    it 'refuses things that play no notes' do
      expect { MB::Sound.seq(MB::Sound::C4).played_by(42) }.to raise_error(ArgumentError, /instrument/)
      expect { MB::Sound.grid(16, kick: 'x...').played_by(arp) }.to raise_error(ArgumentError, /drum machine/)
    end

    it 'plays a chop clip in a Session exactly as clip.sampler(slices)' do
      a = session_render(chop)
      b = session_render { chop.sampler(brk) }
      expect(a[0].abs.max).to be > 0.01
      expect(a).to eq(b)
    end

    it "plays the chop lesson's clip on its break with bg, as .sampler does" do
      rec = MB::Sound.bounce(2.bars, bpm: 138.75) {
        MB::Sound.tr808(MB::Sound.grid(16, kick: 'X.....x...X.....|X.x.......X..x..', snare: '....X..3.3..X..3|.3..X..3....X.3.', hat: 'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx'))
      }
      l_brk = rec.slices(32).name(k: 0..1, h: 2..3, s: 4..5, g: 7)
      t = MB::Sound::T
      l_amen = l_brk.chop(:k, t, :h, :g, :s, t, [:g, 2], :k, t, :k, :h, t, :s, t, [:s, 3], l_brk[:s].rev).loop
      expect(session_render(l_amen, frames: 96000)).to eq(session_render(frames: 96000) { l_amen.sampler(l_brk) })
    end

    it 'plays a grid on the kit design it came from' do
      m = MB::Sound.kit { voice(:zap) { |h| h.fm(800, index: 3, decay: 0.05) } }
      beat = m.grid(16, zap: 'x..x').loop
      expect(beat.instrument).to equal(m)
      MB::Sound.seed(1)
      expect(described_class.graph(beat).description).to start_with('kit')
      expect(session_render(beat, frames: 9600)).to eq(session_render(frames: 9600) { m.kit(beat) })
    end

    it 'plays a grid on a drum machine module' do
      beat = MB::Sound.grid(16, kick: 'x...').played_by(MB::Sound::Drums::TR909)
      expect(described_class.graph(beat).description).to start_with('tr909')
      expect(session_render(beat, frames: 9600)).to eq(session_render(frames: 9600) { MB::Sound.tr909(beat) })
    end

    it 'prints chop clips through their recipe, which marks them again' do
      code = chop.to_ruby
      expect(code).to include('.chop(')
    end
  end

  describe 'with bg, render, and write' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    it 'renders a Sample and a Clip to a file' do
      path = tmp_path('two.flac')
      seconds = MB::Sound.render(path, arp, MB::Sound.seq(MB::Sound::C4).n8)
      expect(seconds).to be > 0.3
      data = MB::Sound.read(path)
      expect(data[0].abs.max).to be > 0.01
    end

    it 'writes a Sample without the master gain' do
      path = tmp_path('arp.flac')
      MB::Sound.write(path, arp)
      data = MB::Sound.read(path)
      expect(data.length).to eq(2)
      expect(data[0].abs.max).to be_within(0.02).of(arp.peak)
    end

    it 'writes audio data as before' do
      path = tmp_path('data.flac')
      MB::Sound.write(path, [Numo::SFloat[0, 0.5, -0.5, 0.25]])
      expect(MB::Sound.read(path)[0].to_a).to eq([0, 0.5, -0.5, 0.25])
    end

    it 'plays a chop clip with bg' do
      ENV['OUTPUT_TYPE'] = 'null'
      chop = arp.slices(4).chop(0, 1, 2, 3).loop
      entry = MB::Sound.bg(:breaks, chop)
      expect(entry.name).to eq(:breaks)
      expect(MB::Sound.players[:breaks]).to start_with('4 slices')
    ensure
      ENV.delete('OUTPUT_TYPE')
    end

    it 'gives bg the friendly message' do
      ENV['OUTPUT_TYPE'] = 'null'
      expect { MB::Sound.bg(Object.new) }.to raise_error(MB::Sound::Playable::Unplayable, /Can't play Object/)
    ensure
      ENV.delete('OUTPUT_TYPE')
    end
  end
end
