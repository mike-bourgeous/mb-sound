# Racks (R1 of the racks project, design/notes/racks.md): Rack values,
# constructors, typed ports, binding, composition, named racks, recipes, and
# graph document round trips of anonymous racks.
RSpec.describe(MB::Sound::Rack) do
  # (knobs, racks, and players made here join the default Session; see
  # spec/support/session_guard.rb)
  after { MB::Sound::Session.existing&.close }

  let(:s) { MB::Sound }
  let(:clip) { s.seq(s::C4, s::E4, s::G4).n8.loop }
  let(:session) { MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, sleep: false)) }

  around(:each) do |ex|
    MB::Sound::Session.with_context(session: session) { ex.run }
  ensure
    session.close
  end

  def events_of(stream, seconds = 1r)
    MB::Sound::MIDI::Stream.for(stream).reader.next(seconds).map { |e| [e.type, e.time, e.note] }
  end

  describe 'constructors' do
    it 'fixes the main input type and kind' do
      expect(s.mrack { it }.kind).to eq(:note_fx)
      expect(s.irack { it.synth { |v| v.hz.saw } }.kind).to eq(:instrument)
      expect(s.arack { it }.kind).to eq(:effect)
      expect(s.lrack { it }.kind).to eq(:listener)
      expect(s.modrack { it }.kind).to eq(:modulator)
      expect(s.rack(in: :audio, out: :notes) { it }.kind).to eq(:listener)
      expect(s.mrack(out: :audio) { it }.kind).to eq(:instrument)
    end

    it 'has full-word aliases' do
      expect(s.method(:note_rack)).to eq(s.method(:mrack))
      expect(s.method(:audio_rack)).to eq(s.method(:arack))
      expect(s.method(:instrument_rack)).to eq(s.method(:irack))
      expect(s.method(:listener_rack)).to eq(s.method(:lrack))
      expect(s.method(:amrack)).to eq(s.method(:lrack))
      expect(s.method(:mod_rack)).to eq(s.method(:modrack))
    end

    it 'is a frozen value naming its ports' do
      r = s.arack(side: :audio) { |sig, side:| sig + side }
      expect(r).to be_frozen
      expect(r.name).to be_nil
      expect(r.signature).to eq('audio(sig) + audio(side) -> ?')
      expect(s.mrack { it }.input.name).to eq(:stream)
      expect(s.irack { |keys| keys.synth { |v| v.hz.saw } }.signature).to eq('notes(keys) -> audio')
    end

    it 'needs a block with an input parameter' do
      expect { s.mrack }.to raise_error(ArgumentError, /block/)
      expect { s.mrack { 1 } }.to raise_error(ArgumentError, /first parameter/)
      expect { s.rack { |x| x } }.to raise_error(ArgumentError, /in:/)
      expect { s.rack(in: :audo) { |x| x } }.to raise_error(ArgumentError, /did you mean\? audio/)
    end
  end

  describe 'applying' do
    it 'works with then, call, .(), and Stream#through' do
      up = s.mrack { it.transpose(12) }
      want = events_of(clip.stream.transpose(12))
      expect(events_of(clip.then(&up))).to eq(want)
      expect(events_of(up.call(clip))).to eq(want)
      expect(events_of(up.(clip.stream))).to eq(want)
      expect(events_of(clip.stream.through(up))).to eq(want)
    end

    it 'keeps a Notes a Notes' do
      n = clip.notes
      out = n.then(&s.mrack { it.transpose(12) })
      expect(out).to be_a(MB::Sound::Notes)
    end

    it 'builds a fresh subgraph for each application' do
      r = s.arack { it.softclip }
      sig = 110.hz.saw
      a = r.(sig)
      b = r.(sig)
      expect(a).not_to equal(b)
      expect(a).to be_a(MB::Sound::GraphNode::Shaper)
    end

    it 'puts no node at a port (the block gets the value itself)' do
      sig = 110.hz.saw
      expect(s.arack { it }.(sig)).to equal(sig)
    end

    it 'sounds like the graph it builds' do
      r = s.arack { it.softclip.filter(:lowpass, cutoff: 900) }
      a = r.(110.hz.saw)
      b = 110.hz.saw.softclip.filter(:lowpass, cutoff: 900)
      expect(a.sample(800)).to eq(b.sample(800))
    end

    it 'checks the output type when given' do
      expect { s.irack { it.transpose(1) }.(clip) }.to raise_error(TypeError, /should output audio/)
      expect { s.mrack(out: :notes) { it.synth { |v| v.hz.saw } }.(clip) }.to raise_error(TypeError, /should output notes/)
      expect { s.lrack { it.softclip }.(110.hz.saw) }.not_to raise_error
    end

    it 'checks the input type' do
      expect { s.arack { it }.(clip) }.to raise_error(TypeError, /wants audio.*through \.synth/)
      expect { s.mrack { it }.(110.hz.saw) }.to raise_error(TypeError, /wants notes/)
    end

    it 'explains wrong-domain methods on a port value' do
      expect { s.mrack { it.lowpass(800) }.(clip) }.to raise_error(NoMethodError, /stream is a notes port.*\.synth makes audio/)
      expect { s.arack { |sig| sig.arp(:up) }.(110.hz.saw) }.to raise_error(NoMethodError, /sig is an audio port.*arp is a note transform/)
    end
  end

  describe 'extra ports' do
    let(:dub) { s.arack(side: :audio) { |sig, side:| sig * side } }

    it 'binds with #with and at the call' do
      x = 110.hz.saw
      y = 3.hz.lfo
      out = x.then(&dub.with(side: y))
      expect(out).to be_a(MB::Sound::GraphNode::Multiplier)
      ref = 110.hz.saw * 3.hz.lfo
      expect(dub.(110.hz.saw, side: 3.hz.lfo).sample(800)).to eq(ref.sample(800))
    end

    it 'raises for an unbound required port' do
      expect { dub.(110.hz.saw) }.to raise_error(ArgumentError, /needs port side: \(audio\)/)
    end

    it 'makes ports with block defaults optional' do
      r = s.arack(depth: :control) { |sig, depth: 0.5| sig * depth }
      expect(r.signature).to eq('audio(sig) + control(depth)? -> ?')
      expect(r.(1.constant).sample(4).to_a).to eq([0.5] * 4)
      expect(r.(1.constant, depth: 0.25).sample(4).to_a).to eq([0.25] * 4)
    end

    it 'checks the block keywords against the declared ports, with did_you_mean' do
      expect { s.arack(keys: :notes) { |sig, key:| sig } }.to raise_error(ArgumentError, /port :keys isn't a keyword.*did you mean\? key/)
      expect { s.arack { |sig, keys:| sig } }.to raise_error(ArgumentError, /keys: isn't a declared port/)
      expect { s.arack(keys: :note) { |sig, keys:| sig } }.to raise_error(ArgumentError, /did you mean\? notes/)
      expect { dub.with(sid: 1) }.to raise_error(ArgumentError, /no port :sid.*did you mean\? side/)
    end

    it 'coerces values to the port type: numbers, knob names, bus names' do
      r = s.arack(gain: :control) { |sig, gain:| sig * gain }
      expect(r.(1.constant, gain: 0.5).sample(3).to_a).to eq([0.5] * 3)

      session.knob(:depth, 0.25)
      out = r.(1.constant, gain: :depth)
      expect(out.graph.any? { |n| n.is_a?(MB::Sound::GraphNode::Knob::Reader) || n.is_a?(MB::Sound::GraphNode::Knob) }).to eq(true)

      side = s.arack(side: :audio) { |sig, side:| side }
      expect(side.(1.constant, side: :drums).to_a[0]).to be_a(MB::Sound::GraphNode::BusTap::Channel)
    end

    it 'takes notes ports' do
      r = s.arack(keys: :notes) { |sig, keys:| sig * keys.gate }
      out = 110.hz.saw.then(&r.with(keys: clip))
      expect(out.graph.any? { |n| n.is_a?(MB::Sound::Notes::Gate) }).to eq(true)
    end
  end

  describe 'in: :auto' do
    it 'reads the types from parameter names and prints them' do
      r = nil
      expect { r = s.rack(:sc, in: :auto) { |sig, keys:, depth: 0.5| sig } }.to output(/rack :sc inferred audio\(sig, keys: notes, depth: control\) -> \?/).to_stdout
      expect(r.input.type).to eq(:audio)
      expect(r.ports.transform_values(&:type)).to eq(keys: :notes, depth: :control)
    end

    it "can't read it or _1 blocks" do
      expect { s.rack(in: :auto) { it } }.to raise_error(ArgumentError, /name the parameter/)
      expect { s.rack(in: :auto) { _1 } }.to raise_error(ArgumentError, /name the parameter/)
      expect { s.rack(in: :auto) { |thing| thing } }.to raise_error(ArgumentError, /can't tell the type of thing/)
    end
  end

  describe 'composition' do
    it 'follows Proc#>> and #<< order' do
      up = s.mrack { it.transpose(12) }
      fifth = s.mrack { it.transpose(7) }
      only_c4 = s.mrack { it.keys(72) }
      expect(events_of((up >> only_c4).(clip)).map(&:last).uniq).to eq([72])
      expect(events_of((only_c4 << up).(clip)).map(&:last).uniq).to eq([72])
      expect(events_of((up >> fifth).(clip))).to eq(events_of(clip.stream.transpose(19)))
      expect((up >> fifth)).to be_composed
    end

    it 'composes with procs' do
      r = s.mrack { it.transpose(12) } >> ->(st) { st.transpose(-12) }
      expect(events_of(r.(clip))).to eq(events_of(clip.stream))
    end

    it 'checks types across the joint' do
      inst = s.irack { it.synth { |v| v.hz.saw } }
      expect { inst >> s.mrack { it } }.to raise_error(TypeError, /outputs audio but anonymous mrack takes notes/)
      expect { inst >> s.arack { it.softclip } }.not_to raise_error
    end
  end

  describe 'named racks' do
    it 'registers in the Session namespace and lists ports' do
      r = s.arack(:dub, side: :audio) { |sig, side:| sig * side }
      expect(s.rack(:dub)).to equal(r)
      expect(session.names.kind(:dub)).to eq(:rack)
      expect(s.racks[:dub]).to eq('effect audio(sig) + audio(side) -> ?, not used yet')

      sig = 110.hz.saw.then(&s.rack(:dub).with(side: 3.hz.lfo))
      session.add(sig, name: :bass)
      expect(s.racks[:dub]).to eq('effect audio(sig) + audio(side) -> audio, 1 use (in :bass)')
    end

    it 'looks up with did_you_mean' do
      s.mrack(:pads) { it.chord(:min7) }
      expect { s.rack(:pad) }.to raise_error(KeyError, /did you mean\? pads/)
    end

    it 'collides with other names through live_error' do
      session.knob(:wobble, 0.5)
      expect { s.mrack(:wobble) { it } }.to raise_error(ArgumentError, /already a knob/)
    end

    it 'prints itself' do
      r = s.arack(:dub, side: :audio) { |sig, side:| sig.softclip * side }
      expect(r.to_ruby).to eq('arack(:dub, side: :audio) { |sig, side:| sig.softclip * side }')
      expect(s.mrack { it.transpose(12) }.to_ruby).to eq('mrack { it.transpose(12) }')
    end
  end

  describe 'recipes and graph documents' do
    it 'prints an application as src.then(&rack)' do
      g = 110.hz.saw.then(&s.arack { it.softclip }) * 0.5
      expect(g.to_ruby).to eq("(110.hz.saw.then(&arack { |sig|\n  sig.softclip\n}) * 0.5)").or eq("110.hz.saw.then(&arack { |sig|\n  sig.softclip\n}) * 0.5")
    end

    it 'prints a named rack by name and bound ports with with' do
      s.arack(:dub, side: :audio) { |sig, side:| sig * side }
      g = 110.hz.saw.then(&s.rack(:dub).with(side: 3.hz.lfo))
      expect(g.to_ruby).to eq('110.hz.saw.then(&rack(:dub).with(side: 3.hz.lfo))')
    end

    it 'round-trips anonymous racks through graph documents, bit for bit' do
      graphs = [
        -> { 110.hz.saw.then(&s.arack { it.softclip.filter(:lowpass, cutoff: 900) }) * 0.5 },
        -> { 110.hz.saw.then(&s.arack(side: :audio) { |sig, side:| sig.softclip * side }.with(side: 3.hz.lfo)) },
        -> { 110.hz.saw.then(&s.arack(depth: :control) { |sig, depth: 0.5| sig * depth }) },
        -> { clip.then(&s.irack { |stream| stream.synth { |v| v.hz.saw * v.amp_env } }) },
      ]
      graphs.each do |make|
        MB::Sound.seed(1)
        g = make.()
        text = MB::Sound::GraphIO.dump(g, name: 'r')
        loaded = MB::Sound::GraphIO.load(text)
        MB::Sound.seed(1)
        ref = make.()
        4.times do
          expect(loaded.sample(800)).to eq(ref.sample(800)), text
        end
        expect(MB::Sound::GraphIO.dump(loaded, name: 'r').sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
      end
    end
  end

  describe 'note streams merge with +' do
    it 'merges streams and Notes' do
      a = -> { s.seq(s::C4).n4.loop.stream }
      b = -> { s.seq(s::G4).n4.loop.stream }
      expect(events_of(a.() + b.())).to eq(events_of(a.().merge(b.())))
      expect(events_of(a.() + b.()).map(&:last).uniq.sort).to eq([60, 67])
      expect((clip.notes + b.())).to be_a(MB::Sound::Notes)
    end
  end
end
