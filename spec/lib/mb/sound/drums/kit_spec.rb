RSpec.describe(MB::Sound::Drums::Kit, :aggregate_failures) do
  def collect(node, seconds = 5)
    out = []
    total = 0
    while total < seconds * 48000 && (buf = node.sample(800))
      out << buf.dup
      total += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  def peak(data, from, to)
    data[(from * 48000).round...(to * 48000).round].abs.max
  end

  describe 'MB::Sound.tr808' do
    it 'plays each grid row on the voice it names, by voice name, alias, or GM name' do
      kit = MB::Sound.tr808(MB::Sound.grid(16, bd: 'x...', snare: '..x.', hat: 'xxxx', open_hat: 'x...', ride: 'x...', high_bongo: 'x...'))
      expect(kit.names).to eq([:kick, :snare, :closed_hat, :open_hat, :cymbal, :high_conga])
      expect(kit[:kick]).to be_a(MB::Sound::Drums::Voice)
      expect(kit.machine).to eq(:tr808)
      expect(kit.to_s).to include('tr808 kit', 'kick')
    end

    it 'mixes several rows on one voice' do
      kit = MB::Sound.tr808(MB::Sound.grid(4, kick: 'x...', bd: '..x.'))
      expect(kit.names).to eq([:kick])
      data = collect(kit, 1.5)
      expect(peak(data, 1.0, 1.05)).to be > peak(data, 0.95, 1.0) * 2
    end

    it 'sums its voices like the voices built alone' do
      MB::Sound.seed(0)
      kit = MB::Sound.tr808(MB::Sound.grid(4, kick: 'x...', snare: '.x..'), skip_idle: false)
      MB::Sound.seed(0)
      kick = MB::Sound::Drums::TR808.kick(MB::Sound.grid(4, 'x...'), skip_idle: false)
      snare = MB::Sound::Drums::TR808.snare(MB::Sound.grid(4, '.x..'), skip_idle: false)
      a = collect(kit, 1)
      b = collect(kick, 1) + collect(snare, 1)
      expect((a - b).abs.max).to be < 1e-6
    end

    describe 'outputs: :separate' do
      let(:pattern) { MB::Sound.grid(16, kick: 'X...x...', snare: '....X..x', hat: 'x.x.xXx.', open_hat: '.x...x..', cymbal: 'x.......', cowbell: '..x...X.') }

      # Samples every channel of +outs+ in turn per buffer (as a Session
      # does), returning one Array per channel.
      def collect_channels(outs, seconds)
        data = outs.map { [] }
        (seconds * 48000 / 800).ceil.times do
          outs.each_with_index { |o, i| data[i] << (o.sample(800) || Numo::SFloat.zeros(800)).dup }
        end
        data.map { |d| Numo::SFloat.hstack(d) }
      end

      it 'gives one named channel per voice in VOICES order' do
        outs = MB::Sound.tr808(pattern, outputs: :separate)
        expect(outs).to be_a(MB::Sound::GraphNode::Channels)
        expect(outs.names).to eq([:kick, :snare, :closed_hat, :open_hat, :cymbal, :cowbell])
        expect(outs[:snare]).to be_a(MB::Sound::Drums::Voice).and(have_attributes(name: :snare))
        expect(outs.graph_node_name).to eq('tr808 outputs')
        expect(MB::Sound.tr808(pattern, outputs: :individual).channel_count).to eq(6)
        expect { MB::Sound.tr808(pattern, outputs: :stereo) }.to raise_error(ArgumentError, /Unknown outputs: :stereo/)
      end

      [true, false].each do |skip|
        it "adds up to the mixed kit bit for bit, with chokes and the shared metal bank (skip_idle: #{skip})" do
          MB::Sound.seed(0)
          mixed = collect(MB::Sound.tr808(pattern.loop, skip_idle: skip), 2.5)
          MB::Sound.seed(0)
          outs = MB::Sound.tr808(pattern.loop, skip_idle: skip, outputs: :separate)
          channels = collect_channels(outs, 2.5)

          sum = Numo::SFloat.zeros(mixed.length)
          channels.each { |c| sum.inplace + c[0...mixed.length] }
          expect(sum).to eq(mixed)

          # The closed hat (step 2 = 0.25 s at 120 BPM) chokes the open hat
          # (step 1 = 0.125 s; 0.45 s decay)
          oh = channels[outs.channel_index(:open_hat)]
          expect(peak(oh, 0.27, 0.35)).to be < 0.01 * peak(oh, 0.125, 0.2)
          expect(peak(channels[outs.channel_index(:cowbell)], 0.25, 0.3)).to be > 0.05
        end
      end
    end

    it 'takes per-voice knobs by voice name or alias' do
      kit = MB::Sound.tr808(MB::Sound.grid(16, kick: 'x', cowbell: 'x'), bd: { tune: 40 }, cowbell: { level: 0.1, decay: 0.5 })
      expect(kit[:kick].knobs[:tune]).to eq(40)
      expect(kit[:cowbell].knobs).to include(level: 0.1, decay: 0.5)
    end

    it 'has more cowbell' do
      plain = MB::Sound.tr808(MB::Sound.grid(16, cowbell: 'x'))
      more = MB::Sound.tr808(MB::Sound.grid(16, cowbell: 'x'), more_cowbell: true)
      even_more = MB::Sound.tr808(MB::Sound.grid(16, cowbell: 'x'), cowbell: { level: 1 }, more_cowbell: 12)
      expect((more[:cowbell].knobs[:level] / plain[:cowbell].knobs[:level]).to_db).to be_within(0.01).of(6)
      expect(even_more[:cowbell].knobs[:level]).to be_within(1e-9).of(12.db)

      # The decay grows with the level: x 2 ** (dB / 12)
      expect(plain[:cowbell].knobs[:decay]).to eq(0.5)
      expect(more[:cowbell].knobs[:decay]).to be_within(1e-9).of(0.5 * Math.sqrt(2))
      expect(even_more[:cowbell].knobs[:decay]).to be_within(1e-9).of(1.0)
      given = MB::Sound.tr808(MB::Sound.grid(16, cowbell: 'x'), cowbell: { decay: 0.2 }, more_cowbell: -12)
      expect(given[:cowbell].knobs[:decay]).to be_within(1e-9).of(0.1)
      expect(given[:cowbell].knobs[:level]).to be_within(1e-9).of(0.45 * -12.db)
    end

    it 'chokes the open hat with the closed hat' do
      kit = MB::Sound.tr808(MB::Sound.grid(16, open_hat: 'x...', closed_hat: '..x.'), open_hat: { decay: 2 }, closed_hat: { level: 0 })
      data = collect(kit, 0.4)
      expect(peak(data, 0.27, 0.35)).to be < 0.01 * peak(data, 0, 0.1)
    end

    it 'shares one metal bank among the hats and cymbal with the same tune' do
      kit = MB::Sound.tr808(MB::Sound.grid(16, hat: 'x.......', open_hat: '....x...', cymbal: 'x.......').loop)
      banks = kit.graph.select { |n| n.respond_to?(:graph_node_name) && n.graph_node_name.to_s == '808 metal' }.uniq
      expect(banks.length).to eq(1)
      # Sleeping voices keep reading their branch of the shared bank
      expect { collect(kit, 3) }.not_to raise_error
    end

    it 'routes GM notes of a MIDI clip, building only the voices it plays' do
      clip = MB::Sound.seq(MB::Sound::Note.new(36), MB::Sound::Note.new(56), MB::Sound::Note.new(46)).n4
      kit = MB::Sound.tr808(clip)
      expect(kit.names).to eq([:open_hat, :cowbell, :kick].sort_by { |v| MB::Sound::Drums::TR808::VOICES.keys.index(v) })
      data = collect(kit, 2)
      expect(peak(data, 0, 0.1)).to be > 0.2
      expect(peak(data, 0.5, 0.6)).to be > 0.1
    end

    it 'builds every voice for a MIDI stream, or only some, with map overrides' do
      stream = -> { MB::Sound::MIDI::Stream.for(MB::Sound.seq(MB::Sound::Note.new(60)).n4) }
      expect(MB::Sound.tr808(stream.()).names.length).to eq(16)
      expect(MB::Sound.tr808(stream.(), only: [:kick, :hh]).names).to eq([:kick, :closed_hat])

      kit = MB::Sound.tr808(stream.(), only: :kick, map: { kick: 60 })
      expect(peak(collect(kit, 0.2), 0, 0.2)).to be > 0.2
    end

    it 'plays a Notes, like the console midi' do
      notes = MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::Note.new(38)).n4)
      kit = MB::Sound.tr808(notes, only: :snare)
      expect(peak(collect(kit, 0.2), 0, 0.2)).to be > 0.2
    end

    it 'ends after a finite pattern rings out, and loops forever' do
      finite = collect(MB::Sound.tr808(MB::Sound.grid(16, hat: 'x.x.')), 10)
      expect(finite.length).to be < 48000
      looping = MB::Sound.tr808(MB::Sound.grid(16, hat: 'x.x.').loop)
      expect(collect(looping, 3).length).to eq(3 * 48000)
      expect(looping.ended?).to eq(false)
    end

    it 'raises for rows and voices that are not 808 voices' do
      expect { MB::Sound.tr808(MB::Sound.grid(16, tambourine: 'x')) }.to raise_error(ArgumentError, /doesn't name a TR-808 voice/)
      expect { MB::Sound.tr808(MB::Sound.grid(16, kick: 'x'), tabla: { tune: 1 }) }.to raise_error(ArgumentError, /Unknown TR-808 voice/)
      expect { MB::Sound.tr808(MB::Sound.grid(16, kick: 'x'), kick: 3) }.to raise_error(ArgumentError, /Hash/)
      expect { MB::Sound.tr808(MB::Sound.seq(MB::Sound::Note.new(90)).n4) }.to raise_error(ArgumentError, /Nothing/)
    end

    it 'lands hits on the grid in a Session render' do
      MB::Sound.bpm(120)
      kit = MB::Sound.tr808(MB::Sound.grid(4, claves: 'x.x.').loop)
      path = tmp_path('kit.flac')
      MB::Sound.render(path, kit, bars: 1)
      data = MB::Sound.read(path)[0]
      onsets = (data.abs > 0.01).where.to_a
      expect(onsets.first).to be < 10
      expect(onsets.find { |i| i > 24000 }).to be_within(10).of(48000)
    ensure
      MB::Sound.rewind
    end
  end
end
