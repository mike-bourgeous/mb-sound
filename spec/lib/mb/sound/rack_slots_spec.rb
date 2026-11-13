# Rack slots (racks R3, design/notes/racks.md, Slots): named, swappable
# holes in a graph, swapped on an exact frame with the master chains'
# handover (spill-over, crossfade, cut).
RSpec.describe('rack slots') do
  after { MB::Sound::Session.existing&.close }

  let(:s) { MB::Sound }
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:buffer) { 800 }
  let(:session) {
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: buffer)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: buffer, realtime: false, raise_errors: true)
  }

  around(:each) do |ex|
    MB::Sound::Session.with_context(session: session) { ex.run }
  ensure
    session.close
  end

  def render(frames, size = buffer, sess = session)
    out = []
    done = 0
    while done < frames
      n = [size, frames - done].min
      out << sess.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  # The session frame of timeline position +pos+ (whole notes) at 120 BPM.
  def frame_of(pos)
    (pos * 2 * 48000).round
  end

  describe 'GraphNode#slot' do
    it 'plays its content bit for bit like the content alone' do
      a = 220.hz.saw.at(0.5).slot(:color) { |x| x.softclip(0.2, 0.5).lp4(1200) }
      b = 220.hz.saw.at(0.5).softclip(0.2, 0.5).lp4(1200)
      expect(a).to be_a(MB::Sound::GraphNode::Slot::Output)
      3.times { expect(a.sample(800)).to eq(b.sample(800)) }
    end

    it "takes a whole bundle, with its content's channels" do
      st = 110.hz.saw.stereo.slot(:w) { |x| x * 0.5 }
      expect(st).to be_a(MB::Sound::GraphNode::Channels)
      l, r = st.map { |o| o.sample(400) }
      expect(l).to eq(r)
      expect(l.abs.max).to be > 0.1

      mono = 110.hz.saw.stereo.slot(:m) { |x| x.mono }
      expect(mono).to be_a(MB::Sound::GraphNode::Slot::Output)
    end

    it 'refuses names that are not Symbols and a missing block' do
      expect { 1.constant.slot('x') { it } }.to raise_error(ArgumentError, /Symbols/)
      expect { 1.constant.slot(:x) }.to raise_error(ArgumentError, /needs a block/)
    end

    it 'prints as Ruby with its content' do
      a = 220.hz.saw.slot(:color) { |x| x.softclip(0.2, 0.5) }
      expect(a.to_ruby).to match(/\.slot\(:color\) \{ \|x\|\s+x\.softclip\(0\.2, 0\.5\)\s+\}/)
    end
  end

  describe 'names' do
    it "names a rack's slot after the rack, per instance once two players use it, with a group" do
      s.arack(:dub) { |sig| sig.slot(:color) { |x| x * 0.5 } }
      session.add(1.constant.then(&s.rack(:dub)), name: :bass)
      expect(session.racks.slots.keys).to eq([:"dub/color"])
      expect(session.names.kind(:"dub/color")).to eq(:slot)

      session.add(2.constant.then(&s.rack(:dub)), name: :keys)
      expect(session.racks.slots.keys).to contain_exactly(:"bass/dub/color", :"keys/dub/color")
      expect(session.names.kind(:"dub/color")).to eq(:slot_group)
      expect(session.racks.slots_for(:"dub/color").length).to eq(2)
    end

    it "names slots outside racks after the player" do
      session.add(1.constant.slot(:tone) { |x| x * 0.5 }, name: :lead)
      expect(session.racks.slots.keys).to eq([:"lead/tone"])
    end

    it 'shares the instance key of the rack knobs' do
      s.arack(:dk) { |sig| sig.slot(:color) { |x| x * s.knob(:amt, 0.5) } }
      session.add(1.constant.then(&s.rack(:dk)), name: :a)
      session.add(1.constant.then(&s.rack(:dk)) + 1.constant.then(&s.rack(:dk)), name: :b)
      expect(session.racks.slots.keys).to contain_exactly(:"a/dk/color", :"b/dk/color", :"b/dk.2/color")
    end
  end

  describe 'swap' do
    def play_constant(content_gain = 0.25)
      session.add(1.constant.slot(:x) { |c| c * content_gain }, name: :p)
    end

    it 'cuts over on the exact frame of its launch point (fade: 0)' do
      play_constant
      render(800)
      e = session.swap_slot(:"p/x", ->(c) { c * 0.75 }, start_time: 1/7r, fade: 0)
      out = render(frame_of(1/7r) + 1000 - 800)
      sw = frame_of(1/7r) - 800
      expect(session.journal[e.seq].lands.frame).to eq(frame_of(1/7r))
      expect(out[sw - 1]).to eq(0.25)
      expect(out[sw]).to eq(0.75)
      expect(out[(sw + 1)..].to_a.uniq).to eq([0.75])
    end

    it 'spills the old content over by default: its tail rings out, silence in' do
      session.add(1.constant.slot(:x) { |c| c.delay(480.samples) }, name: :p)
      render(800)
      session.swap_slot(:"p/x", ->(c) { c * 0.5 }, start_time: 1/7r)
      sw = frame_of(1/7r) - 800
      out = render(sw + 2000)
      expect(out[sw - 1]).to be_within(1e-6).of(1)
      expect(out[sw]).to be_within(1e-6).of(1.5)
      expect(out[sw + 479]).to be_within(1e-6).of(1.5)
      expect(out[sw + 480]).to be_within(1e-6).of(0.5)
      expect(out[sw + 1999]).to be_within(1e-6).of(0.5)

      # The old content is dropped once quiet
      render(48000 * 2)
      expect(session.racks.slots_for(:"p/x").first.chains.length).to eq(1)
    end

    it 'crossfades over fade: bars' do
      play_constant(0.0)
      render(800)
      session.swap_slot(:"p/x", ->(c) { c * 1.0 }, start_time: 1/4r, fade: 1/4r)
      sw = frame_of(1/4r) - 800
      len = frame_of(1/4r)
      out = render(sw + len + 100)
      expect(out[sw - 1]).to eq(0)
      expect(out[sw + len / 2]).to be_within(1e-3).of(0.5)
      expect(out[sw + len + 50]).to eq(1)
    end

    it 'gives the same samples at any buffer size' do
      outs = [800, 367].map { |size|
        sess = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size),
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: size, realtime: false, raise_errors: true)
        MB::Sound::Session.with_context(session: sess) {
          sess.add(220.hz.saw.at(0.5).slot(:x) { |c| c.delay(0.01).lp4(900) }, name: :p)
          render(800, size, sess)
          sess.swap_slot(:"p/x", ->(c) { c.softclip(0.1, 0.3) }, start_time: 1/7r)
          sess.swap_slot(:"p/x", ->(c) { c.lp1(500) }, start_time: 3/7r, fade: 1/8r)
          render(48000 * 3, size, sess)
        }.tap { sess.close }
      }
      # Spill-overs and cuts bit for bit; a crossfade's ramp (Handover.ramp,
      # as master chains have it) steps its gain per buffer, within 1e-7
      sw = frame_of(3/7r) - 800
      expect(outs[1][0...sw]).to eq(outs[0][0...sw])
      expect((outs[1] - outs[0]).abs.max).to be < 1e-7
    end

    it 'records the swap in the journal and undoes it' do
      play_constant
      render(800)
      session.command('swap') { session.swap_slot(:"p/x", ->(c) { c * 0.75 }, on: :now, fade: 0) }
      render(1600)
      expect(render(800).to_a.uniq).to eq([0.75])
      expect(session.journal.changes.map(&:kind)).to include(:slot)
      session.undo(on: :now)
      render(800)
      expect(render(800).to_a.uniq).to eq([0.25])
    end

    it 'swaps every instance through a group name' do
      s.arack(:g) { |sig| sig.slot(:c) { |x| x * 0.25 } }
      session.add(1.constant.then(&s.rack(:g)), name: :a)
      session.add(1.constant.then(&s.rack(:g)), name: :b)
      render(800)
      session.swap_slot(:"g/c", s.arack { |x| x * 0.5 }, on: :now, fade: 0)
      render(800)
      expect(render(800).to_a.uniq).to eq([1.0])
    end

    it 'prints the content playing in documents once it lands' do
      play_constant
      session.swap_slot(:"p/x", s.arack { |c| c * 0.75 }, on: :now, fade: 0)
      render(800)
      slot = session.racks.slots_for(:"p/x").first
      expect(slot.result.to_ruby).to include('c * 0.75')
    end

    it 'explains an unknown slot name' do
      play_constant
      expect { session.swap_slot(:"p/y", ->(c) { c }) }.to raise_error(ArgumentError, /No slot named :"p\/y".*did you mean\? p\/x/)
    end

    it 'refuses a rack of another input type' do
      play_constant
      expect { session.swap_slot(:"p/x", s.mrack { it }) }.to raise_error(ArgumentError, /carries audio/)
    end
  end

  describe 'console swap' do
    it 'swaps a slot by name with a rack or block' do
      session.add(1.constant.slot(:x) { |c| c * 0.25 }, name: :p)
      render(800)
      e = s.swap(:"p/x", on: :now, fade: 0) { |c| c * 0.5 }
      expect(e).to be_a(MB::Sound::Session::Journal::Entry)
      expect(e.kind).to eq(:slot)
      render(800)
      expect(render(800).to_a.uniq).to eq([0.5])
    end
  end
end
