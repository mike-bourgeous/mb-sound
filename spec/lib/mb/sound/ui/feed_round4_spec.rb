# The data UI round 4's panes draw from (design/notes/terminal_ui.md, "UI
# round 4: the feed contract"): bus and send meters, held MIDI notes, the
# clip matrix, rack infos, and the console's launch and tweak.
RSpec.describe('UI round 4 feed') do
  let(:ev) { MB::Sound::MIDI::Event }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session(channels: 2)
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: channels, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: channels, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # Renders +n+ buffers, returning the newest snapshot the feed published.
  def run(session, feed, n, size: 800)
    snap = nil
    n.times do
      session.process_buffer(size)
      s = feed.take
      snap = s if s
    end
    snap
  end

  describe 'bus and send meters' do
    def bus_session
      s = new_session
      feed = MB::Sound::UI::Feed.new
      feed.needs = [:buses]
      s.ui_feed = feed
      s.bus(:verb) { |sig| sig * 0.5 }
      s.route(:a, send: { verb: -6.db })
      s.route(:b, to: :verb)
      s.add(0.25.constant, name: :a, on: :now)
      s.add(0.125.constant, name: :b, on: :now)
      [s, feed]
    end

    it 'gives each bus its input and output, and each send its gain and post-fader level' do
      s, feed = bus_session
      snap = run(s, feed, 30)

      verb = snap.bus_levels[:verb]
      # Input: a's send (0.25 at -6 dB) plus b's whole signal (0.125)
      input = 0.25 * -6.db.to_f + 0.125
      expect(verb.input.peak).to all(be_within(1e-4).of(20 * Math.log10(input)))
      expect(verb.input.rms).to all(be_within(1e-4).of(20 * Math.log10(input)))
      expect(verb.output.peak).to all(be_within(1e-4).of(20 * Math.log10(input * 0.5)))

      send = snap.send_levels[[:a, :verb]]
      expect(send.gain).to be_within(1e-9).of(-6)
      expect(send.level.peak).to all(be_within(1e-4).of(20 * Math.log10(0.25 * -6.db.to_f)))
      # A route to: is the bus's input, not a send
      expect(snap.send_levels.keys).to eq([[:a, :verb]])
    end

    it 'has a short-term level that settles on the signal over about 300 ms' do
      s, feed = bus_session
      early = run(s, feed, 2).bus_levels[:verb].input.short
      late = run(s, feed, 150).bus_levels[:verb].input.short
      level = 20 * Math.log10(0.25 * -6.db.to_f + 0.125)
      expect(early).to be < level - 3
      expect(late).to be_within(0.01).of(level)
    end

    it 'shows a send turned to 0 at minus infinity, and forgets signals gone for a second' do
      s, feed = bus_session
      run(s, feed, 5)
      s.feed(:a, :verb, 0, smooth: 0)
      snap = run(s, feed, 5)
      expect(snap.send_levels[[:a, :verb]].gain).to eq(-Float::INFINITY)

      s.route(:a, send: {})
      snap = run(s, feed, 70)
      expect(snap.send_levels).not_to have_key([:a, :verb])
    end

    it 'gives the same levels with the Ruby mirror' do
      levels = [true, false].map do |native|
        MB::Sound::UI::BusMeter.native = native
        s, feed = bus_session
        snap = run(s, feed, 12)
        [snap.bus_levels, snap.send_levels]
      end
      expect(levels[0]).to eq(levels[1])
    ensure
      MB::Sound::UI::BusMeter.native = true
    end

    it 'publishes nothing for buses unless a pane needs them' do
      s, feed = bus_session
      feed.needs = [:meters]
      snap = run(s, feed, 5)
      expect(snap.bus_levels).to be_nil
      expect(snap.send_levels).to be_nil
    end

    it 'leaves the mix unchanged' do
      s, feed = bus_session
      with = Array.new(10) { s.process_buffer(800)[0].dup.tap { feed.take } }
      s2, = bus_session
      s2.ui_feed = nil
      without = Array.new(10) { s2.process_buffer(800)[0].dup }
      expect(with).to eq(without)
    end
  end

  describe 'held notes' do
    it 'lists the notes held on the input and on labelled added sources' do
      s = new_session
      s.add(0.constant, name: :clock, on: :now)
      feed = MB::Sound::UI::Feed.new
      s.ui_feed = feed
      input = s.midi_in
      input.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(
        ev.parse([0x90, 60, 100], time: 0.01r), ev.parse([0x91, 64, 30], time: 0.02r), ev.parse([0x80, 60, 0], time: 0.3r)
      ))
      input.add_source(MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.parse([0x90, 67, 127], time: 0.05r))), label: :keyboard)

      snap = run(s, feed, 6) # 0.1 s
      expect(snap.notes.map { |n| [n.note, n.velocity, n.channel, n.source] }.sort).to eq([[60, 100, 0, :input], [64, 30, 1, :input], [67, 127, 0, :keyboard]])
      expect(snap.notes.find { |n| n.note == 60 }.frame).to eq((0.01 * 48000).floor)
      expect(snap.notes).to be_frozen

      snap = run(s, feed, 20) # 0.43 s
      expect(snap.notes.map(&:note).sort).to eq([64, 67])
    end

    it 'ends held notes on all notes off and when a source is removed' do
      s = new_session
      s.add(0.constant, name: :clock, on: :now)
      input = s.midi_in
      input.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.parse([0x90, 60, 100], time: 0.01r), ev.parse([0xB0, 123, 0], time: 0.1r)))
      extra = input.add_source(MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.parse([0x92, 70, 90], time: 0.01r))), label: :keyboard)
      3.times { s.process_buffer(800) }
      expect(s.held_notes.map(&:note).sort).to eq([60, 70])
      5.times { s.process_buffer(800) }
      expect(s.held_notes.map(&:note)).to eq([70])
      input.remove_source(extra)
      expect(s.held_notes).to eq([])
    end
  end

  describe 'the clip matrix' do
    let(:s) { new_session(channels: 1) }
    let(:arr) { s.arrangement }
    let(:poll) { MB::Sound::UI::Poll.new(s) }
    let(:riff_a) { MB::Sound.seq(MB::Sound::A1, MB::Sound::A2).n8.loop.named(:riff_a) }
    let(:riff_b) { MB::Sound.seq(MB::Sound::C2, MB::Sound::E2.n4.acc).n8.loop }
    let(:beat) { MB::Sound.grid(16, kick: 'x...x...x...x...').loop.named(:beat) }

    before do
      MB::Sound::Session.with_context(session: s) do
        arr.track(:bass) { |c| c.tone.ramp.at(0.1) * c.amp_env }
        arr.track(:drums) { |k| MB::Sound.tr808(k).at(0.1) }
        arr.scene(:one, bass: riff_a, drums: beat)
        arr.scene(:two, bass: riff_b)
      end
    end

    after { poll.close }

    def matrix
      MB::Sound::Session.with_context(session: s) { poll.call[0].matrix }
    end

    def lane(name) = matrix.tracks.find { |l| l.name == name }

    def bars(n) = (n * 120).round.times { s.process_buffer(800) }

    it 'gives each track its slots in scene order, and each scene its cells' do
      m = matrix
      expect(m.tracks.map(&:name)).to eq([:bass, :drums])
      expect(lane(:bass).slots.map(&:key)).to eq(['riff_a', 'bass#1'])
      expect(lane(:drums).slots.map(&:key)).to eq(['beat'])
      expect(lane(:bass).q).to eq('1')
      expect(m.scenes.map(&:cells)).to eq([{ bass: 0, drums: 0 }, { bass: 1, drums: :stop }])
      expect(lane(:bass).state).to eq(:stopped)
    end

    it 'follows launches through the journal: queued, landed, stopped, and undone' do
      MB::Sound::Session.with_context(session: s) do
        arr.go(:one)
        bars(1.5)
        arr.go(:two)
      end
      m = matrix
      expect(lane(:bass).playing).to eq(0)
      expect(lane(:bass).queued.map { |q| [q.kind, q.slot, q.lands] }).to eq([[:launch, 1, '3:1']])
      expect(lane(:drums).queued.map { |q| [q.kind, q.lands] }).to eq([[:stop, '3:1']])
      expect(m.scenes.find { |x| x.name == :two }.queued.lands).to eq('3:1')

      bars(1)
      expect(lane(:bass).playing).to eq(1)
      expect(lane(:bass).queued).to eq([])
      expect(lane(:drums).state).to eq(:stopped)
      expect(lane(:drums).playing).to be_nil

      MB::Sound::Session.with_context(session: s) { s.undo }
      bars(1)
      expect(lane(:bass).playing).to eq(0)
      expect(lane(:drums).state).to eq(:playing)
    end

    it 'gives the detail pane frozen clip data' do
      info = lane(:bass).slots[1]
      expect(info).to be_frozen
      expect(info.loop).to eq(true)
      expect(info.length).to eq(3/8r)
      expect(info.events.map { |e| [e.start, e.length, e.note, e.marks] }).to eq([[0r, 1/8r, 36, []], [1/8r, 1/4r, 40, [:accent]]])
      expect(info.ruby).to eq('seq(C2, E2.n4.accent).n8.loop') # (acc prints as its official name)
      expect(info.range).to eq(36..40)

      kit = lane(:drums).slots[0]
      expect(kit.events.first.row).to eq(:kick)
      expect(kit.events.length).to eq(4)
    end

    it 'launches slots by name or index, and tweaks the clip into a new slot as one undo step' do
      MB::Sound::Session.with_context(session: s) do
        arr.go(:one)
        bars(1.25)
        e = MB::Sound.launch(:bass, 1)
        expect(e.kind).to eq(:swap)
        bars(1)
        expect(lane(:bass).playing).to eq(1)

        e = MB::Sound.tweak(:bass, transpose: 12)
        expect(e.queued?).to eq(true)
        expect(lane(:bass).slots.map(&:key)).to eq(['riff_a', 'bass#1', 'bass_slot1_v2'])
        expect(lane(:bass).slots[2].history).to eq(['bass#1', 'transpose: 12'])
        expect(s.undo_steps.map(&:label)).to include('tweak :bass, transpose: 12 -> :bass_slot1_v2')
        expect(lane(:bass).queued.map(&:slot)).to eq([2])
        bars(1)
        expect(lane(:bass).playing).to eq(2)
        expect(arr.tracks[:bass].clip.events.map(&:value)).to eq([48, 52])

        MB::Sound.launch(:bass, :riff_a)
        bars(1)
        expect(lane(:bass).playing).to eq(0)

        MB::Sound.undo
        bars(1)
        expect(lane(:bass).playing).to eq(2)
      end
    end

    it 'names tweak versions with a mark valid in Ruby names, keeping the lineage (ux-r4b)' do
      MB::Sound::Session.with_context(session: s) do
        arr.go(:one)
        bars(1.25)
        MB::Sound.tweak(:bass, transpose: 2)
        bars(1)
        MB::Sound.tweak(:bass, :reverse)
        bars(1)
        MB::Sound.launch(:bass, :riff_a)
        bars(1)
        MB::Sound.tweak(:bass, swing: 0.6)
        bars(1)
        names = arr.slots(:bass).map(&:name)
        expect(names).to include(:riff_a_v2, :riff_a_v3, :riff_a_v4)
        expect(names.compact.map(&:to_s)).to all(match(/\A[a-z_][a-zA-Z0-9_]*\z/))
        expect(arr.tweak_history(arr.slots(:bass).find { |c| c.name == :riff_a_v3 })).to eq([:riff_a, ['transpose: 2', ':reverse']])
        expect(arr.tweak_history(arr.slots(:bass).find { |c| c.name == :riff_a_v4 })).to eq([:riff_a, ['swing: 0.6']])
        expect(lane(:bass).slots.find { |c| c.key == 'riff_a_v3' }.history).to eq(['riff_a', 'transpose: 2', ':reverse'])
        expect(MB::Sound.launch(:bass, :riff_a_v3)).not_to be_nil # (version names launch by name)
      end
    end

    it 'makes every tweak' do
      clip = riff_b
      results = {
        [:reverse, nil] => clip.reverse, [:halftime, nil] => clip.halftime, [:doubletime, nil] => clip.doubletime,
        [:legato, 0.5] => clip.legato(0.5), [:swing, 0.6] => clip.swing(0.6), [:quantize, 1/4r] => clip.quantize(1/4r),
        [:quantize, true] => clip.quantize, [:transpose, -12] => clip.transpose(-12),
      }
      results.each do |(op, value), expected|
        got = arr.send(:tweaked, :bass, clip, op, value)
        expect(got.events.map(&:to_h)).to eq(expected.events.map(&:to_h)), "#{op} #{value}"
      end
      double = arr.send(:tweaked, :bass, clip, :double, nil)
      expect(double.length).to eq(3/4r)
      expect(double.looping?).to eq(true)
      half = arr.send(:tweaked, :bass, clip, :half, nil)
      expect(half.length).to eq(3/16r)
      expect(arr.send(:tweaked, :drums, beat, :halftime, nil).rows[:kick].length).to eq(2)
    end

    it 'explains wrong names, slots, and transforms' do
      MB::Sound::Session.with_context(session: s) do
        arr.go(:one)
        bars(1)
        expect { MB::Sound.launch(:bass, 9) }.to raise_error(ArgumentError, /2 slots \(0\.\.1; got 9\)/)
        expect { MB::Sound.launch(:bass, :rif_a) }.to raise_error(ArgumentError, /did you mean :riff_a/)
        expect { MB::Sound.launch(:bas, 0) }.to raise_error(ArgumentError, /No track :bas/)
        expect { MB::Sound.tweak(:bass, :revers) }.to raise_error(ArgumentError, /did you mean reverse/)
        expect { MB::Sound.tweak(:bass, :reverse, transpose: 1) }.to raise_error(ArgumentError, /one transform/)
        expect { MB::Sound.tweak(:bass, transpose: 0.5) }.to raise_error(ArgumentError, /integer/)
        expect { MB::Sound.tweak(:drums, transpose: 2) }.to raise_error(ArgumentError, /kit can't transpose/)
      end
    end

    it 'merges the per-buffer player state into the lane state' do
      snap = MB::Sound::UI::Snapshot.fake(parts: [MB::Sound::UI::PartLoad.new(name: :bass, kind: :player, state: :ringing, load: 0.0)].freeze)
      expect(snap.lane_state(:bass)).to eq(:ringing)
      expect(snap.lane_state(:drums)).to eq(:stopped)
    end
  end

  it 'lists rack instances in the poll, with their knobs' do
    s = new_session(channels: 1)
    poll = MB::Sound::UI::Poll.new(s)
    MB::Sound::Session.with_context(session: s) do
      dub = MB::Sound.arack(:dub_feed) { |sig| sig * MB::Sound.knob(:space, 0.3) }
      s.add(0.1.constant.then(&dub), name: :pad, on: :now)
      slow, knobs = poll.call
      info = slow.racks.find { |r| r.name == :dub_feed }
      expect(info).not_to be_nil
      expect(info.knobs).to eq([:"dub_feed/space"])
      expect(knobs.map(&:first)).to include(:"dub_feed/space")
    end
  ensure
    poll&.close
  end

  it 'gives buses their senders and sources' do
    s = new_session(channels: 1)
    s.bus(:verb) { |sig| sig }
    s.route(:a, send: { verb: 0.5 })
    s.route(:b, to: :verb)
    poll = MB::Sound::UI::Poll.new(s)
    bus = poll.call[0].buses.first
    expect([bus.sends, bus.sources]).to eq([[:a], [:b]])
  ensure
    poll&.close
  end
end
