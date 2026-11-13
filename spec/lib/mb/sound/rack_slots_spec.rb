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

    it 'lands on the exact frame from a scheduled block, traced from inside the slot, at any buffer size' do
      [800, 367].each do |size|
        sess = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size),
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: size, realtime: false, raise_errors: true)
        MB::Sound::Session.with_context(session: sess) {
          sess.add(1.constant.slot(:x) { |c| c * 0.25 }, name: :p)
          slot = sess.racks.slots_for(:"p/x").first
          started = nil
          s.at_bar(2, beat: 2) { s.swap(:"p/x", ->(c) { c.proc { |b| started ||= MB::Sound::Session.span.frame; b } * 0.75 }, on: :now, fade: 0) }
          out = render(frame_of(1) + frame_of(1/4r) + 1000, size, sess)
          sw = frame_of(1) + frame_of(1/4r)
          expect(out[sw - 1]).to eq(0.25)
          expect(out[sw]).to eq(0.75)
          expect(slot.current.start).to eq(sw)
          expect(started).to be <= sw # (the span holding the landing)
        }.tap { sess.close }
      end
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

    it "leaves the player's clips alone: a pass-through swap renders bit for bit like no swap" do
      # (racks-r3's session fuzz: Feeds listed the slot's input, so the new
      # content's timeline nodes included the player's clip, restarted on
      # the swap frame)
      outs = [false, true].map { |swap|
        sess = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 367),
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 137.5), channels: 1, buffer_size: 367, realtime: false, raise_errors: true)
        MB::Sound::Session.with_context(session: sess) {
          part = s.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.loop.synth(voices: 2) { |v| v.hz.saw * v.amp_env(0.002, 0.05, 0.6, 0.02) * 0.2 }
          sess.add(part.slot(:tint) { |x| x * 1.0 }, name: :x1)
          render(800, 367, sess)
          sess.swap_slot(:"x1/tint", ->(x) { x * 1.0 }, start_time: 3/7r, fade: 0) if swap
          render(48000 * 2, 367, sess)
        }.tap { sess.close }
      }
      expect(outs[1]).to eq(outs[0])
    end

    it 'plays to the end like its content alone when the input ends (a one-shot clip into a delay)' do
      # (racks-r3's session fuzz, seeds 80 and 142: the content read the
      # whole buffer while the input had ended inside it; a swap landing
      # after the input ended dropped the frames before it)
      outs = [[:plain, 800], [:slot, 800], [:slot, 367], [:swap, 367], [:swap, 800]].map { |kind, size|
        sess = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size),
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 174), channels: 1, buffer_size: size, realtime: false, raise_errors: true)
        MB::Sound::Session.with_context(session: sess) {
          part = s.seq(MB::Sound::C5, MB::Sound::D5).n8.synth(voices: 2) { |v| v.hz.saw * v.amp_env(0.002, 0.05, 0.6, 0.02) * 0.2 }
          g = kind == :plain ? part.delay(1.n16, feedback: 0.3) : part.slot(:tint) { |x| x.delay(1.n16, feedback: 0.3) }
          sess.add(g, name: :x2)
          sess.swap_slot(:"x2/tint", ->(x) { x.lp1(600) }, start_time: 1/2r) if kind == :swap
          out = []
          out << sess.process_buffer[0].dup while sess.players.any? && out.length < 2000
          SpecBuffers.join(out)
        }.tap { sess.close }
      }
      same = ->(a, b) {
        n = [a.length, b.length].min
        expect(a[0...n]).to eq(b[0...n])
        expect((a.length > n ? a[n..] : b[n..]).abs.max.to_f).to eq(0) unless a.length == b.length
      }
      expect(outs[1]).to eq(outs[0])
      same.(outs[2], outs[0])
      same.(outs[3], outs[4])
    end

    it 'explains an unknown slot name' do
      play_constant
      expect { session.swap_slot(:"p/y", ->(c) { c }) }.to raise_error(ArgumentError, /No slot named :"p\/y".*did you mean\? p\/x/)
    end

    it 'refuses a rack of another input type' do
      play_constant
      expect { session.swap_slot(:"p/x", s.mrack { it }) }.to raise_error(ArgumentError, /slot :"p\/x" takes audio; anonymous mrack takes notes/)
    end
  end

  describe 'listings and documents' do
    before do
      s.arack(:dub) { |sig| sig.slot(:color) { |x| x.softclip(0.3, 0.6) } * s.knob(:space, 0.5) }
    end

    it "lists slots in racks, RackInfo, and help rack(:x), with the content playing" do
      expect(s.racks[:dub]).to include('slots color (Shaper)')
      expect(s.rack(:dub).info.slots).to eq([{ name: :color, path: nil, type: :audio, content: 'Shaper' }])
      expect(Ractor.shareable?(s.rack(:dub).info)).to eq(true)

      session.add(220.hz.saw.then(&s.rack(:dub)), name: :bass)
      session.swap_slot(:"dub/color", ->(c) { c.lp4(500) }, on: :now, fade: 0)
      render(800)
      expect(s.racks[:dub]).to include('slots color (FourPole)')
      info = session.racks.rack_info[:dub].first
      expect(info.slots).to eq([{ name: :color, path: :"dub/color", type: :audio, content: 'FourPole' }])
      expect(info.knobs).to eq([:"dub/space"])
      require 'mb/sound/help'
      page = MB::Sound::Help::RackPage.new(s.rack(:dub), nil).to_s
      expect(page).to match(/slots.*\n\s+color\s+FourPole\s+:"dub\/color"/)
    end

    it "saves a named rack instance's swapped slot with using, and loads it back" do
      g = 220.hz.saw.then(&s.rack(:dub))
      session.add(g, name: :bass)
      session.swap_slot(:"dub/color", ->(c) { c.lp4(500) }, on: :now, fade: 0)
      render(800)
      doc = MB::Sound::GraphIO.dump(g, name: 'x')
      expect(doc).to include('color: arack { |c| c.lp4(500) }')
      expect(doc).not_to include('osc.slot') # (the rack's definition keeps its default)
      loaded = MB::Sound::GraphIO.load(doc)
      slot = loaded.graph.grep(MB::Sound::GraphNode::Slot::Output).map(&:owner_slot).find { |sl| sl.name == :color }
      expect(slot.current.description).to eq('FourPole')
      expect(MB::Sound::GraphIO.dump(loaded, name: 'x').sub(/saved: "[^"]*"/, '')).to eq(doc.sub(/saved: "[^"]*"/, ''))
    end

    it 'prints a swapped slot inside an anonymous rack with its content' do
      g = 1.constant.then(&s.arack { |sig| sig.slot(:tint) { |x| x * 0.25 } + 1 })
      session.add(g, name: :lead)
      session.swap_slot(:"lead/tint", ->(c) { c * 0.75 }, on: :now, fade: 0)
      render(800)
      expect(g.to_ruby).to match(/slot\(:tint\) \{ \|c\|\s+c \* 0\.75\s+\}/)
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g, name: 'y'))
      expect(loaded.sample(10).to_a.uniq).to eq([1.75])
    end
  end

  describe 're-defining a named rack' do
    it 'swaps every playing instance on the next bar, keeping its knobs and ports, as one undo step' do
      s.arack(:dub, side: :audio) { |sig, side:| sig * s.knob(:space, 0.5) + side * 0.0 }
      session.add(1.constant.then(&s.rack(:dub).with(side: 0.constant)), name: :bass)
      session.add(2.constant.then(&s.rack(:dub).with(side: 0.constant)), name: :keys)
      render(800)
      s.turn(:"bass/dub/space", 0.25)
      render(800)
      expect(render(800).to_a.uniq).to eq([1.25])

      s.arack(:dub, side: :audio) { |sig, side:| sig * s.knob(:space, 0.5) * 2 + side }
      bar = frame_of(1) - 2400
      e = session.journal.changes.last
      expect(e.kind).to eq(:rack)
      expect(e.lands.pos).to eq(1)
      out = render(bar + 48000 * 2)
      expect(out[bar - 1]).to eq(1.25)
      expect(out[bar]).to eq(2.5) # (the old instances spill over: silent in, silent out)
      expect(out[-1]).to eq(2.5)
      expect(session.knobs.keys).to contain_exactly(:"bass/dub/space", :"keys/dub/space")
      expect(s.rack(:dub).block).not_to be_nil

      session.undo(on: :now)
      render(800)
      expect(render(800).to_a.uniq).to eq([1.25])
      expect(s.rack(:dub).to_ruby).not_to include('* 2')
    end

    it "lands on the exact frame with swap :name, rack, on:, fade: 0, and documents print the new definition" do
      s.arack(:tone) { |sig| sig * 0.25 }
      g = 1.constant.then(&s.rack(:tone))
      session.add(g, name: :a)
      render(800)
      e = s.swap(:tone, s.arack { |x| x * 0.75 }, at: s.bar(1, beat: 3), on: :now, fade: 0)
      expect(e.kind).to eq(:rack)
      sw = frame_of(1/2r) - 800
      out = render(sw + 100)
      expect(out[sw - 1]).to eq(0.25)
      expect(out[sw]).to eq(0.75)
      expect(MB::Sound::GraphIO.dump(g, name: 'x')).to include("arack(:tone) { |x|\n  x * 0.75\n}")
    end

    it "names the new definition's slots as the old ones were, so swaps find them" do
      s.arack(:dc) { |sig| sig.slot(:color) { |x| x * 0.25 } }
      session.add(1.constant.then(&s.rack(:dc)), name: :a)
      render(800)
      s.arack(:dc) { |sig| sig.slot(:color) { |x| x * 0.5 } + 1 }
      render(48000 * 2)
      expect(render(800).to_a.uniq).to eq([1.5])
      session.swap_slot(:"dc/color", ->(x) { x * 2 }, on: :now, fade: 0)
      render(800)
      expect(render(800).to_a.uniq).to eq([3.0])
    end

    it 'leaves listener racks and anonymous racks unwrapped' do
      expect(1.constant.then(&s.arack { |x| x * 2 })).to be_a(MB::Sound::GraphNode::Multiplier)
      s.lrack(:lvl) { |x| x.abs }
      expect(1.constant.then(&s.rack(:lvl))).not_to be_a(MB::Sound::GraphNode::Slot::Output)
      s.arack(:wrapped) { |x| x * 2 }
      expect(1.constant.then(&s.rack(:wrapped))).to be_a(MB::Sound::GraphNode::Slot::Output)
    end
  end

  describe 'instrument slots (notes in, audio out)' do
    # Old voices keep the notes they started (patch persist); notes from the
    # swap frame on go to the new content
    def persist_render(size, swap_at: 1/8r, fade: nil, rack: false)
      sess = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size),
                                    transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: size, realtime: false, raise_errors: true)
      MB::Sound::Session.with_context(session: sess) {
        clip = s.events([0r, 1/2r, 60, 0.8], [1/4r, 1/8r, 64, 0.8], length: 1)
        if rack
          s.irack(:keys) { |n| n.synth(voices: 4) { |v| v.gate * 0.25 } }
          sess.add(clip.then(&s.rack(:keys)), name: :lead)
          s.swap(:keys, s.irack { |n| n.synth(voices: 4) { |v| v.gate * 0.5 } }, at: s.bar(1, beat: 1.5), on: :now, fade: fade)
        else
          sess.add(clip.notes.slot(:keys) { |n| n.synth(voices: 4) { |v| v.gate * 0.25 } }, name: :lead)
          sess.swap_slot(:"lead/keys", ->(n) { n.synth(voices: 4) { |v| v.gate * 0.5 } }, start_time: swap_at, fade: fade)
        end
        out = []
        (96000 * 2 / size).times { out << sess.process_buffer(size)[0].dup }
        SpecBuffers.join(out)
      }.tap { sess.close }
    end

    it 'keeps sounding notes on the old content and gives new notes to the new one, on exact frames' do
      [800, 367].each do |size|
        x = persist_render(size)
        f = ->(pos) { (pos * 96000).round }
        expect(x[f.(1/8r) - 1]).to eq(0.25)
        expect(x[f.(1/8r)]).to eq(0.25)  # (the held note stays on the old content)
        expect(x[f.(1/4r) - 1]).to eq(0.25)
        expect(x[f.(1/4r)]).to eq(0.75)  # (the new note on the new one)
        expect(x[f.(3/8r)]).to eq(0.25)
        expect(x[f.(1/2r)]).to eq(0)
      end
    end

    it 'swaps an instrument rack defined again with patch persist' do
      x = persist_render(800, rack: true)
      f = ->(pos) { (pos * 96000).round }
      expect(x[f.(1/8r)]).to eq(0.25)
      expect(x[f.(1/4r)]).to eq(0.75)
      expect(x[f.(1/2r)]).to eq(0)
    end

    it 'cuts the old voices with fade: 0' do
      x = persist_render(800, fade: 0)
      f = ->(pos) { (pos * 96000).round }
      expect(x[f.(1/8r) - 1]).to eq(0.25)
      expect(x[f.(1/8r)]).to eq(0)
      expect(x[f.(1/4r)]).to eq(0.5)
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
