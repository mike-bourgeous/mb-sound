RSpec.describe('meter map') do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  describe MB::Sound::Sequence::Transport do
    before { transport.meter(7/8r, at: 8) } # bar 9 onward in 7/8

    it 'numbers bars through meter changes' do
      expect(transport.meters.map(&:to_s)).to eq(['bar 1: 4/4', 'bar 9: 7/8'])
      expect(transport.bar_at(4)).to eq(5)
      expect(transport.bar_at(8)).to eq(9)
      expect(transport.bar_at(8 + 7/8r)).to eq(10)
      expect(transport.bar_position(10)).to eq(8 + 7/8r)
      expect(transport.bar_position(9.5r)).to eq(8 + 7/16r)
      expect(transport.bar_length(7)).to eq(1)
      expect(transport.bar_length(9)).to eq(7/8r)
      expect(transport.bars_length(7, 2)).to eq(1 + 7/8r)
    end

    it 'finds the next bar line and N-bar lines counted from bar 1' do
      expect(transport.next_bar_line(8.1r)).to eq(8 + 7/8r)
      expect(transport.next_bar_line(8 + 7/8r)).to eq(8 + 7/8r)
      expect(transport.next_bar_line(5.5r, 4)).to eq(8) # bar 9
      expect(transport.next_bar_line(8.5r, 4)).to eq(8 + 4 * 7/8r) # bar 13
    end

    it 'reports bar and beat at the position' do
      transport.seek(8 + 7/8r + 1/4r)
      expect([transport.bar, transport.beat]).to eq([10, 2])
    end

    it 'puts meter changes on bar lines and forgets later ones' do
      expect { transport.meter(3/4r, at: 8.5r) }.to raise_error(ArgumentError, /bar lines/)
      transport.meter(3/4r, at: 4)
      expect(transport.meters.map(&:to_s)).to eq(['bar 1: 4/4', 'bar 5: 3/4'])
      transport.bar_length = 1
      expect(transport.meters.length).to eq(1)
    end
  end

  describe 'sessions and launch points' do
    let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
    let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

    after { session.close }

    def within(&block)
      MB::Sound::Session.with_context(session: session, &block)
    end

    it 'changes meter at the next bar line with `meter 7, 8`, keeping earlier bar numbers' do
      session.add(1.constant, name: :x, on: :now)
      session.process_buffer while transport.position < 2.5r
      m = within { MB::Sound.meter(7, 8) }
      expect(m.pos).to eq(3)
      expect(m.bar).to eq(4)
      expect(within { MB::Sound.meter }).to eq(['bar 1: 4/4', 'bar 4: 7/8'])
      expect(within { MB::Sound.time_signature(3, at: MB::Sound.bar(6)) }.pos).to eq(3 + 2 * 7/8r)
      expect { within { MB::Sound.meter(7, 6) } }.to raise_error(ArgumentError, /power of two/)
    end

    it 'places bar(n), at_bar, :bar, and N-bar alignments through the map, and stamps count through it' do
      transport.meter(3/4r, at: 4) # bar 5 onward in 3/4
      session.add(1.constant, name: :x, on: :now)
      session.process_buffer

      expect(MB::Sound.bar(7).whole_notes(transport)).to eq(4 + 2 * 3/4r)
      e = session.change(:test, :x, MB::Sound::LaunchPoint.build(at: MB::Sound.bar(7, beat: 2), on: nil, offset: nil).resolve(now: 0, transport: transport)) { |_t| }
      expect(e.entry.lands.to_s).to eq('7:2')

      transport.seek(4.1r)
      expect(MB::Sound::LaunchPoint.on(:bar).resolve(now: 4.1r, transport: transport)).to eq(4.75r)
      expect(MB::Sound::LaunchPoint.on(4).resolve(now: 4.1r, transport: transport)).to eq(4 + 4 * 3/4r) # bar 9
      expect(MB::Sound::LaunchPoint.build(at: nil, on: nil, offset: 2).resolve(now: 4r, transport: transport)).to eq(5.5r)

      ran = []
      within { MB::Sound.at_bar(7) { ran << session.now } }
      session.process_buffer while transport.position < 6
      expect(ran).to eq([4 + 2 * 3/4r])
      expect(session.stamp(4 + 2 * 3/4r).to_s).to eq('7:1')
    end

    it 'counts plain-number form sections in the meter where they start' do
      set = session.arrangement
      set.track(:x) { |c| c.notes.number }
      set.scene(:four, x: MB::Sound.seq(48).n1.loop)
      set.scene(:seven, x: MB::Sound.seq(50).n8.loop)
      transport.meter(7/8r, at: 2)
      within do
        MB::Sound.flow(seed: 1, on: :now) do
          four 2
          seven 2
          ending 1, scene: :four
        end
      end
      session.process_buffer while transport.position < 4
      starts = session.journal.changes.select { |e| e.kind == :scene && e.status == :landed }.map { |e| [e.subject, e.lands.pos, e.lands.to_s] }
      expect(starts).to eq([[:four, 0r, '1:1'], [:seven, 2r, '3:1'], [:four, 2 + 7/4r, '5:1']])
    end
  end
end
