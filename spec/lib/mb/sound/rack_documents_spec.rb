# Rack documents and graph document format 4 (racks R2,
# design/notes/racks.md and graph_io.md): typed inputs, outputs, racks
# saved and loaded as Racks with their macros, and graphs carrying the
# definitions of the named racks they use.
RSpec.describe('rack documents') do
  let(:s) { MB::Sound }
  let(:io) { MB::Sound::GraphIO }
  let(:session) {
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 800)
    MB::Sound::Session.new(master_gain: 1, output: out, channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
  }

  around(:each) do |ex|
    MB::Sound::Session.with_context(session: session) { ex.run }
  ensure
    session.close
  end

  def without_saved(text)
    text.sub(/saved: "[^"]*"/, '')
  end

  let(:dub) {
    s.arack(:dub, side: :audio, depth: :control) { |sig, side:, depth: 0.5|
      space = s.macro(:space, 0.3)
      cut = s.macro(:cut, 800, range: 100..8000, curve: :exp, description: 'Tone')
      sig.filter(:lowpass, cutoff: cut.mod(0.5.hz.lfo, depth: 0.1)).delay(0.1, feedback: space * 0.5, wet: space) * depth + side
    }
  }

  describe 'saving a rack' do
    it 'writes typed inputs, outputs, the kind, and the macros as knob lines' do
      text = io.dump(dub)
      expect(text).to start_with('# mb-sound rack document')
      expect(text).to match(/^graph 4, name: "dub", kind: :effect, rack: :arack, saved: /)
      expect(text).to include("inputs sig: :audio, side: :audio, depth: [:control, 0.5]\noutputs :audio\n")
      expect(text).to include(%(knob :space, 0.3\nknob :cut, 800.0, range: 100.0..8000.0, curve: :exp, description: "Tone"\n))
      expect(text).to end_with("\nsig.filter(:lowpass, cutoff: cut.mod(0.5.hz.lfo, depth: 0.1)).delay(0.1, feedback: space * 0.5, wet: space) * depth + side\n")
    end

    it 'saves every kind' do
      {
        s.irack(:keys) { |stream| stream.synth { |v| v.hz.triangle * v.amp_env * s.macro(:level, 0.5) } } => [:instrument, :irack, 'stream: :notes'],
        s.mrack(:up) { it.transpose(12) } => [:note_fx, :mrack, 'stream: :notes'],
        s.lrack(:lvl) { |sig| sig.abs.filter(:lowpass, cutoff: 10) } => [:listener, :lrack, 'sig: :audio'],
        s.modrack(:wb) { |ctl| ctl * 0.5 + 0.5 } => [:modulator, :modrack, 'ctl: :control'],
      }.each do |r, (kind, ctor, input)|
        text = io.dump(r)
        expect(text).to include("kind: #{kind.inspect}").and include("rack: #{ctor.inspect}").and include("inputs #{input}")
        loaded = io.load(text)
        expect(loaded).to be_a(MB::Sound::Rack)
        expect(loaded.kind).to eq(kind)
        expect(without_saved(io.dump(loaded))).to eq(without_saved(text))
      end
    end

    it 'keeps share: and follow: on knob lines' do
      r = s.arack(:sh) { |sig| sig * s.macro(:wet, 0.5, share: true) * s.macro(:amt, 2, range: 1..4, follow: :morph) }
      text = io.dump(r)
      expect(text).to include("knob :wet, 0.5, share: true\nknob :amt, 2.0, range: 1.0..4.0, follow: :morph\n")
      loaded = io.load(text)
      s.knob(:morph, 1)
      s.bg(:a, 1.constant.then(&loaded))
      expect(session.knobs.keys).to contain_exactly(:morph, :wet, :"sh/amt")
      expect(session.knobs[:"sh/amt"].macro.follow).to eq(:morph)
    end

    it 'refuses share: in graph documents that are not racks' do
      expect { io.load("graph 4\nknob :x, 0.5, share: true\nx * 1") }.to raise_error(io::LoadError, /share: and follow: are for rack documents/)
    end

    it 'refuses composed racks' do
      expect { io.dump(s.mrack { it } >> s.mrack { it }) }.to raise_error(io::DumpError, /composed/)
    end
  end

  describe 'loading a rack document' do
    it 'gives a Rack that sounds like the original, and saves the same text again' do
      text = io.dump(dub)
      r = io.load(text)
      expect(r.name).to eq(:dub)
      expect(r.signature).to eq('audio(sig) + audio(side) + control(depth)? -> audio')
      expect(io.parse(text)).to be_rack
      expect(without_saved(io.dump(r))).to eq(without_saved(text))

      a = 220.hz.ramp.then(&dub.with(side: 110.hz.sine))
      b = 220.hz.ramp.then(&r.with(side: 110.hz.sine))
      expect(b.sample(9600)).to eq(a.sample(9600))
    end

    it 'applies the rack when the inputs are given' do
      text = io.dump(dub)
      g = io.load(text, inputs: { sig: 220.hz.ramp, side: 110.hz.sine, depth: 0.25 })
      want = 220.hz.ramp.then(&dub.with(side: 110.hz.sine, depth: 0.25))
      expect(g.sample(4800)).to eq(want.sample(4800))
      expect { io.load(text, inputs: { sig: 220.hz.ramp }) }.to raise_error(io::LoadError, /missing input side/)
      expect { io.load(text, inputs: { sig: 1.constant, side: 1.constant, sid: 2 }) }.to raise_error(io::LoadError, /no input sid/)
    end

    it 'makes macros for each application, named like any rack\'s' do
      r = io.load(io.dump(dub))
      s.bg(:bass, 1.constant.then(&r.with(side: 0.constant)))
      expect(session.knobs.keys).to contain_exactly(:"dub/space", :"dub/cut")
      s.bg(:keys, 1.constant.then(&r.with(side: 0.constant)))
      expect(session.knobs.keys).to contain_exactly(:"bass/dub/space", :"bass/dub/cut", :"keys/dub/space", :"keys/dub/cut")
    end

    it 'loads older documents with untyped inputs unchanged' do
      doc = io.parse("graph 3\ninputs :midi, :input\nparam :x, 1\ninput * x")
      expect(doc.input_types).to eq(midi: :notes, input: :audio)
      expect(doc).not_to be_rack
      g = io.load("graph 3\ninputs :input\ninput * 2", inputs: { input: 1.constant })
      expect(g.sample(4)[0]).to eq(2)
      expect(io.dump(g)).to include('inputs input: :audio')
    end

    it 'checks typed inputs and outputs lines' do
      expect { io.parse("graph 4\ninputs sig: :sound\nsig") }.to raise_error(io::LoadError, /port type/)
      expect { io.parse("graph 4\noutputs :midi\n1.constant") }.to raise_error(io::LoadError, /outputs takes port types/)
      doc = io.parse("graph 4\ninputs sig: :audio\noutputs :audio\nsig")
      expect(doc.input_types).to eq(sig: :audio)
      expect(doc.outputs).to eq([:audio])
    end
  end

  describe 'graphs using named racks' do
    it 'carry the rack definitions, so they load where the rack is not defined' do
      g = 220.hz.ramp.then(&dub.with(side: 110.hz.sine))
      text = io.dump(g, name: 'song')
      expect(text).to include("arack(:dub, side: :audio, depth: :control) { |sig, side:, depth: 0.5|\n")
      expect(text).to include('macro(:space, 0.3)')
      expect(text).to include("220.hz.ramp.then(&rack(:dub).with(side: 110.hz.sine))\n")

      other = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false))
      begin
        loaded = MB::Sound::Session.with_context(session: other) { io.load(text) }
        expect(other.racks[:dub]).to be_a(MB::Sound::Rack)
        expect(loaded.sample(9600)).to eq(220.hz.ramp.then(&dub.with(side: 110.hz.sine)).sample(9600))
        again = MB::Sound::Session.with_context(session: other) { io.dump(loaded, name: 'song') }
        expect(without_saved(again)).to eq(without_saved(text))
      ensure
        other.close
      end
    end

    it "uses the session's definition where the rack is defined" do
      text = io.dump(1.constant.then(&s.arack(:twice) { |sig| sig * 2 }), name: 'g')
      s.arack(:twice) { |sig| sig * 3 }
      expect(io.load(text).sample(4)[0]).to eq(3)
    end

    describe 'references' do
      around(:each) do |ex|
        old = ENV.to_h.slice('MB_SOUND_PRESETS', 'XDG_DATA_HOME')
        ENV['MB_SOUND_PRESETS'] = tmp_path('presets')
        ENV['XDG_DATA_HOME'] = tmp_path('xdg')
        ex.run
      ensure
        ENV.delete('MB_SOUND_PRESETS')
        ENV.delete('XDG_DATA_HOME')
        old.each { |k, v| ENV[k] = v }
      end

      it 'finds rack(:name) among the presets when nothing defines it' do
        io.save(:halve, s.arack(:halve) { |sig| sig * s.macro(:amount, 0.5) })
        other = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false))
        begin
          g = MB::Sound::Session.with_context(session: other) { io.load("graph 4\n4.constant.then(&rack(:halve))") }
          expect(g.sample(4)[0]).to eq(2)
          expect(other.racks[:halve]).to be_a(MB::Sound::Rack)
          expect { MB::Sound::Session.with_context(session: other) { io.load("graph 4\n4.constant.then(&rack(:halv))") } }.to raise_error(io::LoadError, /rack :halv isn't defined/)
        ensure
          other.close
        end
      end

      it 'gives the Rack from preset, defined in the session, or applies it' do
        expect { s.save(:dubby, dub) }.to output(/Saved dubby/).to_stdout
        expect { s.presets }.to output(/dubby  \(rack effect; inputs: sig \(audio\), side \(audio\), depth \(control\); macros: space, cut\)/).to_stdout

        r = s.preset(:dubby)
        expect(r).to be_a(MB::Sound::Rack)
        expect(s.rack(:dubby)).to equal(r)

        g = s.preset(:dubby, sig: 220.hz.ramp, side: 0.constant)
        expect(g).to be_a(MB::Sound::GraphNode)
        expect(session.knobs.keys).to include(:"dubby/space")
        expect { s.preset(:dubby, side: 0.constant) }.to raise_error(ArgumentError, /main input sig/)
      end
    end
  end
end
