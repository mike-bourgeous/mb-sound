# Rack documents and graph document format 4 (racks R2,
# design/notes/racks.md and graph_io.md): typed inputs, outputs, racks
# saved and loaded as Racks with their knobs, and graphs carrying the
# definitions of the named racks they use.
RSpec.describe('rack documents') do
  # (knobs, racks, and players made here join the default Session; see
  # spec/support/session_guard.rb)
  after { MB::Sound::Session.existing&.close }

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

  # (Sessions made without a transport play on the default one)
  after { MB::Sound.rewind }

  def without_saved(text)
    text.sub(/saved: "[^"]*"/, '')
  end

  let(:dub) {
    s.arack(:dub, side: :audio, depth: :control) { |sig, side:, depth: 0.5|
      space = s.knob(:space, 0.3)
      cut = s.knob(:cut, 800, range: 100..8000, curve: :exp, description: 'Tone')
      sig.filter(:lowpass, cutoff: cut.mod(0.5.hz.lfo, depth: 0.1)).delay(0.1, feedback: space * 0.5, wet: space) * depth + side
    }
  }

  describe 'saving a rack' do
    it 'writes typed inputs, outputs, the kind, and the knobs as knob lines' do
      text = io.dump(dub)
      expect(text).to start_with('# mb-sound rack document')
      expect(text).to match(/^graph 5, name: "dub", kind: :effect, rack: :arack, saved: /)
      expect(text).to include("inputs sig: :audio, side: :audio, depth: [:control, 0.5]\noutputs :audio\n")
      expect(text).to include(%(knob :space, 0.3\nknob :cut, (100..8000).at(800), curve: :exp, description: "Tone"\n))
      expect(text).to end_with("\nsig.filter(:lowpass, cutoff: cut.mod(0.5.hz.lfo, depth: 0.1)).delay(0.1, feedback: space * 0.5, wet: space) * depth + side\n")
    end

    it 'saves every kind' do
      {
        s.irack(:keys) { |stream| stream.synth { |v| v.hz.triangle * v.amp_env * s.knob(:level, 0.5) } } => [:instrument, :irack, 'stream: :notes'],
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
      r = s.arack(:sh) { |sig| sig * s.knob(:wet, 0.5, share: true) * s.knob(:amt, 2, range: 1..4, follow: :morph) }
      text = io.dump(r)
      expect(text).to include("knob :wet, 0.5, share: true\nknob :amt, (1..4).at(2), follow: :morph\n")
      loaded = io.load(text)
      s.knob(:morph, 1)
      s.bg(:a, 1.constant.then(&loaded))
      expect(session.knobs.keys).to contain_exactly(:morph, :wet, :"sh/amt")
      expect(session.knobs[:"sh/amt"].rack_knob.follow).to eq(:morph)
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

      a = 220.hz.saw.then(&dub.with(side: 110.hz.sine))
      b = 220.hz.saw.then(&r.with(side: 110.hz.sine))
      expect(b.sample(9600)).to eq(a.sample(9600))
    end

    it 'applies the rack when the inputs are given' do
      text = io.dump(dub)
      g = io.load(text, inputs: { sig: 220.hz.saw, side: 110.hz.sine, depth: 0.25 })
      want = 220.hz.saw.then(&dub.with(side: 110.hz.sine, depth: 0.25))
      expect(g.sample(4800)).to eq(want.sample(4800))
      expect { io.load(text, inputs: { sig: 220.hz.saw }) }.to raise_error(io::LoadError, /missing input side/)
      expect { io.load(text, inputs: { sig: 1.constant, side: 1.constant, sid: 2 }) }.to raise_error(io::LoadError, /no input sid/)
    end

    it 'makes knobs for each application, named like any rack\'s' do
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
      g = 220.hz.saw.then(&dub.with(side: 110.hz.sine))
      text = io.dump(g, name: 'song')
      expect(text).to include("arack(:dub, side: :audio, depth: :control) { |sig, side:, depth: 0.5|\n")
      expect(text).to include('knob(:space, 0.3)')
      expect(text).to match(/^220\.hz\.saw\.then\(&rack\(:dub\)\.with\(side: 110\.hz\.sine\)\.using\(seed: drawn_seed\(\d+\)\)\)\n/)

      other = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false))
      begin
        loaded = MB::Sound::Session.with_context(session: other) { io.load(text) }
        expect(other.racks[:dub]).to be_a(MB::Sound::Rack)
        expect(loaded.sample(9600)).to eq(220.hz.saw.then(&dub.with(side: 110.hz.sine)).sample(9600))
        again = MB::Sound::Session.with_context(session: other) { io.dump(loaded, name: 'song') }
        expect(without_saved(again)).to eq(without_saved(text))
      ensure
        other.close
      end
    end

    it 'reloads each instance exactly: its seed and its knobs\' current values' do
      def new_session
        MB::Sound::Session.new(master_gain: 1, realtime: false, channels: 1, buffer_size: 800, raise_errors: true,
          output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 800))
      end

      wobbly = s.arack(:wobbly) { |sig|
        texture = s.noise.at(0.05) + s.drift(3, range: -0.1..0.1) + 110.hz.unison(3, detune: 10.cents) { |p, _| p.saw.rnd }.at(0.1)
        (sig + texture).filter(:lowpass, cutoff: s.knob(:tone, 2000, range: 200..8000, curve: :exp)) * s.knob(:level, 0.5)
      }
      g = 220.hz.saw.at(0.2).then(&wobbly) + 330.hz.saw.at(0.2).then(&wobbly)
      s.bg(:pad, g, fade: 0)
      session.process_buffer(800)
      s.turn(:"wobbly/level", 0.8, smooth: 0)
      s.turn(:"wobbly/tone", 900, smooth: 0)
      session.process_buffer(800)
      text = io.dump(g, name: 'pad')
      expect(text).to include("arack(:wobbly) { |sig|\n").and include('knob(:level, 0.5)')
      uses = text.scan(/rack\(:wobbly\)\.using\(seed: drawn_seed\((\d+)\), tone: 900, level: 0\.8\)/)
      expect(uses.length).to eq(2)
      expect(uses.uniq.length).to eq(2) # (each instance its own seed)
      want = 6.times.map { session.process_buffer(800)[0].dup }

      fresh = new_session
      begin
        got = MB::Sound::Session.with_context(session: fresh) {
          loaded = io.load(text)
          s.bg(:pad, loaded, fade: 0)
          2.times { fresh.process_buffer(800) }
          expect(fresh.knobs.keys).to contain_exactly(:"pad/wobbly/level", :"pad/wobbly/tone", :"pad/wobbly.2/level", :"pad/wobbly.2/tone")
          6.times.map { fresh.process_buffer(800)[0].dup }
        }
        expect(got).to eq(want)
        expect(want.map { |b| b.abs.max }.max).to be > 0.01
      ensure
        fresh.close
      end

      # seeds: :fresh leaves the drawn seeds out (new texture), keeping the knobs
      again = io.load(text, seeds: :fresh)
      expect(io.dump(again, name: 'pad')).to include('rack(:wobbly).using(seed: drawn_seed(')
    end

    it 'keeps optional ports as parameters in the definition' do
      text = io.dump(1.constant.then(&dub.with(side: 0.constant)), name: 'g')
      expect(text).to include('|sig, side:, depth: 0.5|').and include('* depth + side')
    end

    describe 'a rack defined differently in the session' do
      let(:text) { io.dump(1.constant.then(&s.arack(:twice) { |sig| sig * 2 }), name: 'g') }

      it 'uses the session\'s rack without asking when the definitions print the same' do
        text
        expect(io.load(text).sample(4)[0]).to eq(2)
        expect(session.racks.names).to eq([:twice])
      end

      it 'raises outside live mode unless racks: chooses' do
        text
        s.arack(:twice) { |sig| sig * 3 }
        expect { io.load(text) }.to raise_error(io::LoadError, /rack :twice in .* differs from the session's; load with racks: .*:twice_2/)
        expect(io.load(text, racks: :session).sample(4)[0]).to eq(3)
        expect { io.load(text, racks: :keep) }.to raise_error(ArgumentError, /racks: must be/)
      end

      it 'loads the saved copy under the next free name for this document with racks: :rename' do
        text
        s.arack(:twice) { |sig| sig * 3 }
        session.names.claim(:twice_2, :track)
        g = nil
        expect { g = io.load(text, racks: :rename) }.to output(/loaded as :twice_3/).to_stdout
        expect(g.sample(4)[0]).to eq(2)
        expect(s.rack(:twice).(1.constant).sample(4)[0]).to eq(3)
        expect(s.rack(:twice_3).(1.constant).sample(4)[0]).to eq(2)
      end

      it 'replaces the session\'s rack with racks: :saved, as one undo step' do
        text
        s.arack(:twice) { |sig| sig * 3 }
        expect(io.load(text, racks: :saved).sample(4)[0]).to eq(2)
        expect(s.rack(:twice).(1.constant).sample(4)[0]).to eq(2)
        expect(session.undo_steps.last.label).to eq('rack :twice from (graph document)')
        session.undo(on: :now)
        expect(s.rack(:twice).(1.constant).sample(4)[0]).to eq(3)
      end

      it 'asks the conflict handler in live mode, with the choices as a value' do
        text
        s.arack(:twice) { |sig| sig * 3 }
        seen = nil
        old = io.rack_conflict_handler
        io.rack_conflict_handler = ->(c) { seen = c; :rename }
        allow(MB::Sound).to receive(:live?).and_return(true)
        g = nil
        expect { g = io.load(text) }.to output(/loaded as :twice_2/).to_stdout
        expect(g.sample(4)[0]).to eq(2)
        expect(seen).to be_a(MB::Sound::Rack::Conflict)
        expect(seen.options).to eq(%i[session saved rename])
        expect(seen.rename_to).to eq(:twice_2)
        expect(seen.session_rack).to equal(session.racks[:twice])
      ensure
        io.rack_conflict_handler = old
      end

      it 'asks on the console in one line' do
        c = MB::Sound::Rack::Conflict.new(name: :dub, session_rack: nil, saved_rack: nil, source: 'song.mbg.rb', rename_to: :dub_2)
        out = StringIO.new
        expect(c.ask(input: StringIO.new("r\n"), output: out)).to eq(:rename)
        expect(out.string).to eq("rack :dub in song.mbg.rb differs from the session's: keep the session's [s], replace it with the saved copy [v], or load the saved copy as :dub_2 [r]? ")
        expect(c.ask(input: StringIO.new("\n"), output: out)).to eq(:session)
        expect(c.ask(input: StringIO.new("v\n"), output: out)).to eq(:saved)
        expect(c.ask(input: StringIO.new(''), output: out)).to be_nil
      end

      it 'records the choice in the take and gives it back when the line replays' do
        text
        s.arack(:twice) { |sig| sig * 3 }
        take = MB::Sound::Take.new(session: session)
        line = take.begin_line('preset :song')
        begin
          io.load(text, racks: :session)
        ensure
          take.end_line
        end
        expect(line.choices).to eq([[:rack, :twice, :session]])
        expect(take.to_ruby).to include(', choices: [[:rack, :twice, :session]]')

        Thread.current[:mb_sound_replay_choices] = line.choices
        begin
          expect(io.load(text).sample(4)[0]).to eq(3) # (no racks:, no error: the take's choice)
        ensure
          Thread.current[:mb_sound_replay_choices] = nil
        end
      end
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
        io.save(:halve, s.arack(:halve) { |sig| sig * s.knob(:amount, 0.5) })
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
        expect { s.presets }.to output(/dubby  \(rack effect; inputs: sig \(audio\), side \(audio\), depth \(control\); knobs: space, cut\)/).to_stdout

        r = s.preset(:dubby)
        expect(r).to be_a(MB::Sound::Rack)
        expect(s.rack(:dubby)).to equal(r)

        g = s.preset(:dubby, sig: 220.hz.saw, side: 0.constant)
        expect(g).to be_a(MB::Sound::GraphNode)
        expect(session.knobs.keys).to include(:"dubby/space")
        expect { s.preset(:dubby, side: 0.constant) }.to raise_error(ArgumentError, /main input sig/)
      end
    end
  end
end
