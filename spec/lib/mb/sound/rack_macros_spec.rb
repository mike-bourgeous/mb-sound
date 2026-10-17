# Rack macros (racks R2, design/notes/racks.md): knobs scoped to a rack,
# named by path, shared or followed on request, with rack snapshots and
# baseline-plus-modulation.
RSpec.describe('rack macros') do
  let(:s) { MB::Sound }
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) {
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 800)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
  }

  around(:each) do |ex|
    MB::Sound::Session.with_context(session: session) { ex.run }
  ensure
    session.close
  end

  def render(frames, size = 800)
    out = []
    done = 0
    while done < frames
      n = [size, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    out.reduce(:concatenate)
  end

  def level_rack(name = :lvl)
    s.arack(name) { |sig| sig * s.macro(:level, 0.5) }
  end

  describe 'macro' do
    it 'is a knob made inside a rack block' do
      k = nil
      s.arack { |sig| k = s.macro(:space, 0.3, range: 0..2); sig * k }.(1.constant)
      expect(k).to be_a(MB::Sound::GraphNode::Knob)
      expect(k.value).to eq(0.3)
      expect(k.range).to eq(0.0..2.0)
      expect(k.macro.macro).to eq(:space)
      expect(k.session).to be_nil
    end

    it 'raises outside a rack block, pointing at knob' do
      expect { s.macro(:space, 0.3) }.to raise_error(ArgumentError, /inside a rack.*knob :space/)
    end

    it 'reads the same knob when asked again by name or with the same definition' do
      ks = []
      s.arack { |sig| ks << s.macro(:a, 0.5) << s.macro(:a) << s.macro(:a, 0.5); sig }.(1.constant)
      expect(ks.uniq(&:object_id).length).to eq(1)
      expect { s.arack { |sig| s.macro(:a, 0.5); s.macro(:a, 0.7); sig }.(1.constant) }.to raise_error(ArgumentError, /twice, differently/)
      expect { s.arack { |sig| s.macro(:a); sig }.(1.constant) }.to raise_error(ArgumentError, /give it a default/)
    end

    it 'makes new knobs for each application' do
      ks = []
      r = s.arack { |sig| ks << s.macro(:a, 0.5); sig }
      r.(1.constant)
      r.(1.constant)
      expect(ks[0]).not_to equal(ks[1])
    end
  end

  describe 'names' do
    it "is the rack's knob path once a graph using it plays, and the listing shows it" do
      s.bg(:bass, 1.constant.then(&level_rack))
      expect(session.knobs.keys).to eq([:"lvl/level"])
      expect(session.names.kind(:"lvl/level")).to eq(:knob)
      expect(s.racks[:lvl]).to include('macros level 0.5 (0..1)')
      expect(level_rack(:lvl).macros).to eq([:"lvl/level"])
    end

    it 'turns like a knob, on exact frames' do
      s.bg(:bass, 1.constant.then(&level_rack), fade: 0)
      render(800)
      s.turn(:"lvl/level", 0.25, smooth: 0)
      data = render(800)
      expect(data[-1]).to be_within(1e-6).of(0.25)
    end

    it 'gives each instance its own knobs once a rack plays in two players' do
      r = level_rack
      s.bg(:bass, 1.constant.then(&r))
      s.turn(:"lvl/level", 0.8, smooth: 0)
      s.bg(:keys, 2.constant.then(&r))
      expect(session.knobs.keys).to contain_exactly(:"bass/lvl/level", :"keys/lvl/level")
      expect(session.names.kind(:"lvl/level")).to eq(:macro_group)
      render(800)
      expect(session.knobs[:"bass/lvl/level"].value).to eq(0.8)
      expect(session.knobs[:"keys/lvl/level"].value).to eq(0.5)

      # The same player again joins its knobs (keeping the value)
      s.bg(:bass, 3.constant.then(&r))
      expect(session.knobs.keys).to contain_exactly(:"bass/lvl/level", :"keys/lvl/level")
      expect(session.knobs[:"bass/lvl/level"].value).to eq(0.8)
      expect(r.macros).to contain_exactly(:"bass/lvl/level", :"keys/lvl/level")
    end

    it 'turns every instance by the short name once they are per instance' do
      r = level_rack
      s.bg(:bass, 1.constant.then(&r), fade: 0)
      s.bg(:keys, 2.constant.then(&r), fade: 0, on: :now)
      entries = s.turn(:"lvl/level", 0.25, smooth: 0)
      expect(entries.length).to eq(2)
      expect(entries.map(&:subject)).to contain_exactly(:"bass/lvl/level", :"keys/lvl/level")
      render(800)
      expect(session.knobs.values.map(&:value)).to eq([0.25, 0.25])
      s.turn(:"keys/lvl/level", 0.75, smooth: 0)
      render(800)
      expect(session.knobs[:"keys/lvl/level"].value).to eq(0.75)
      expect(session.undo_steps.last.label).to eq('turn :"keys/lvl/level"')
      expect(session.undo_steps[-2].changes.length).to eq(2) # (the group turn is one undo step)
    end

    it 'drops the instances of forgotten players' do
      r = level_rack
      s.bg(:bass, 1.constant.then(&r), fade: 0)
      s.bg(:keys, 2.constant.then(&r), fade: 0, on: :now)
      render(800)
      s.stop(:keys, on: :now, fade: 0)
      render(800)
      expect(session.knobs.keys).to contain_exactly(:"bass/lvl/level", :"keys/lvl/level") # (stopped: kept for resume)
      session.forget(:keys)
      render(800)
      expect(session.knobs.keys).to eq([:"bass/lvl/level"])
      expect(session.names.kind(:"keys/lvl/level")).to be_nil
      expect(session.racks.group_members(:"lvl/level").map(&:name)).to eq([:"bass/lvl/level"])

      s.stop(:bass, on: :now, fade: 0)
      render(800)
      session.forget(:bass)
      render(800)
      expect(session.knobs).to be_empty
      expect(session.names.kind(:"lvl/level")).to be_nil
      s.bg(:pad, 1.constant.then(&r))
      expect(session.knobs.keys).to eq([:"lvl/level"]) # (plain names again)
    end

    it 'names two instances in one player apart' do
      r = level_rack
      s.bg(:bass, 1.constant.then(&r) + 2.constant.then(&r))
      s.bg(:keys, 1.constant.then(&r))
      expect(session.knobs.keys).to contain_exactly(:"bass/lvl/level", :"bass/lvl.2/level", :"keys/lvl/level")
    end

    it "scopes an anonymous rack's macros to the player" do
      s.bg(:pad, 1.constant.then(&s.arack { |sig| sig * s.macro(:level, 0.5) }))
      expect(session.knobs.keys).to eq([:"pad/level"])
    end

    it 'takes the rack\'s new range when the same instance plays again' do
      s.bg(:bass, 1.constant.then(&s.arack(:lvl) { |sig| sig * s.macro(:level, 0.5) }))
      s.bg(:bass, 1.constant.then(&s.arack(:lvl) { |sig| sig * s.macro(:level, 0.5, range: 0..4) }))
      expect(session.knobs[:"lvl/level"].range).to eq(0.0..4.0)
    end
  end

  describe 'sharing' do
    it 'joins the session knob of its own name with share: true' do
      cut = s.knob(:cut, 0.25)
      s.bg(:a, 1.constant.then(&s.arack { |sig| sig * s.macro(:cut, 0.5, share: true) }), fade: 0)
      expect(session.knobs.keys).to eq([:cut])
      expect(render(800)[-1]).to eq(0.25)
      s.turn(:cut, 0.75, smooth: 0)
      expect(render(800)[-1]).to eq(0.75)
      expect(session.knobs[:cut]).to equal(cut)
    end

    it 'makes the session knob when there is none' do
      s.bg(:a, 1.constant.then(&s.arack { |sig| sig * s.macro(:wet, 0.5, share: true) }))
      expect(session.knobs.keys).to eq([:wet])
    end

    it 'raises for a shared knob with another range' do
      s.knob(:cut, 0.25)
      expect {
        s.bg(:a, 1.constant.then(&s.arack { |sig| sig * s.macro(:cut, 50, range: 0..100, share: true) }))
      }.to raise_error(ArgumentError, /doesn't match/)
    end

    it 'follows a session knob through its own range and curve with follow:' do
      s.knob(:morph, 0.5)
      s.bg(:a, 1.constant.then(&s.arack(:f) { |sig| sig * s.macro(:amt, 2, range: 1..4, follow: :morph) }), fade: 0)
      expect(render(800)[-1]).to be_within(1e-6).of(2.5)
      s.turn(:morph, 1, smooth: 0)
      expect(render(800)[-1]).to be_within(1e-6).of(4)

      s.bg(:b, 1.constant.then(&s.arack(:g) { |sig| sig * s.macro(:cut, 100, range: 100..1600, curve: :exp, follow: :morph) }), fade: 0, on: :now)
      s.turn(:morph, 0.5, smooth: 0)
      expect(render(800)[-1]).to be_within(1e-3).of(2.5 + 400)
    end

    it 'raises for follow: of a missing knob and for share: with follow:' do
      expect {
        s.bg(:a, 1.constant.then(&s.arack { |sig| sig * s.macro(:amt, 2, range: 1..4, follow: :nope) }))
      }.to raise_error(ArgumentError, /follows knob :nope/)
      expect { s.arack { |sig| s.macro(:a, 0.5, share: true, follow: :x); sig }.(1.constant) }.to raise_error(ArgumentError, /don't go together/)
    end
  end

  describe 'snapshots' do
    it 'snaps only the rack\'s macros and recalls them, in part' do
      r = s.arack(:dub) { |sig| sig * s.macro(:space, 0.3) + s.macro(:tone, 0.2) }
      s.knob(:other, 0.1)
      s.bg(:bass, 1.constant.then(&r))
      r.snap(:wide)
      expect(s.snaps[:"dub/wide"].keys).to contain_exactly(:"dub/space", :"dub/tone")

      s.turn(:"dub/space", 0.9, smooth: 0)
      s.turn(:"dub/tone", 0.9, smooth: 0)
      s.turn(:other, 0.9, smooth: 0)
      render(800)
      entries = s.recall(:"dub/wide", only: [:space])
      expect(entries.length).to eq(1)
      render(800)
      expect(session.knobs[:"dub/space"].value).to be_within(1e-6).of(0.3)
      expect(session.knobs[:"dub/tone"].value).to be_within(1e-6).of(0.9)

      r.recall(:wide, except: [:space])
      render(800)
      expect(session.knobs[:"dub/tone"].value).to be_within(1e-6).of(0.2)
      expect(session.knobs[:other].value).to be_within(1e-6).of(0.9)
      expect { s.recall(:"dub/wide", only: [:spice]) }.to raise_error(ArgumentError, /spice/)
    end

    it 'keeps snapshot values when macros become per instance' do
      r = level_rack
      s.bg(:bass, 1.constant.then(&r))
      r.snap(:a)
      s.bg(:keys, 1.constant.then(&r))
      expect(s.snaps[:"lvl/a"].keys).to eq([:"bass/lvl/level"])
    end
  end

  describe 'mod' do
    it 'adds modulation in fractions of the range around the knob (linear)' do
      k = MB::Sound::GraphNode::Knob.new(:x, 0.5, range: 0..2)
      out = k.mod(1.constant, depth: 0.25).sample(10)
      expect(out[0]).to be_within(1e-6).of(1.0)
      out = MB::Sound::GraphNode::Knob.new(:y, 1.9, range: 0..2).mod(1.constant, depth: 0.25).sample(10)
      expect(out[0]).to be_within(1e-6).of(2.0) # limited to the range
    end

    it 'moves in octaves for exp knobs' do
      k = MB::Sound::GraphNode::Knob.new(:cut, 400, range: 100..1600, curve: :exp)
      expect(k.mod(1.constant, depth: 0.25).sample(4)[0]).to be_within(1e-3).of(800)
      expect(k.mod(-1.constant, depth: 0.25).sample(4)[0]).to be_within(1e-3).of(200)
    end

    it 'follows the knob as it turns' do
      s.bg(:a, s.arack(:m) { |sig| sig * s.macro(:lvl, 0.5).mod(0.constant, depth: 0.1) }.(1.constant), fade: 0)
      expect(render(800)[-1]).to be_within(1e-6).of(0.5)
      s.turn(:"m/lvl", 0.75, smooth: 0)
      expect(render(800)[-1]).to be_within(1e-6).of(0.75)
    end
  end

  describe 'rack info' do
    let(:dub) { s.arack(:dub, side: :audio) { |sig, side:| sig.compress(lookahead: 5.ms).delay(0.1, wet: s.macro(:space, 0.3)) + side } }

    it 'gives frozen RackInfo per instance with ports, latency, and macro knobs' do
      info = session.racks.tap { dub }.rack_info[:dub]
      expect(info.length).to eq(1)
      expect(info[0].path).to be_nil
      expect(info[0].latency).to eq(240)
      expect(info[0].ports.map { |p| [p[:name], p[:type], p[:role]] }).to eq([[:sig, :audio, :main], [:side, :audio, :side]])
      expect(info[0].macros).to eq([:space])

      s.bg(:bass, 1.constant.then(&dub.with(side: 0.constant)))
      s.bg(:keys, 1.constant.then(&dub.with(side: 0.constant)))
      all = session.racks.rack_info
      expect(Ractor.shareable?(all)).to eq(true)
      expect(all[:dub].map(&:path)).to eq([:"bass/dub", :"keys/dub"])
      expect(all[:dub].map(&:macros)).to eq([[:"bass/dub/space"], [:"keys/dub/space"]])
      expect(all[:dub][0].signature).to eq('audio(sig) + audio(side) -> audio')
    end

    it 'explains a rack with help rack(:x)' do
      require 'mb/sound/help'
      dub
      s.bg(:bass, 1.constant.then(&dub.with(side: 0.constant)))
      text = MB::U.remove_ansi(MB::Sound::Help.page_for(s.rack(:dub)).to_s)
      expect(text).to include('rack :dub').and include('effect, audio(sig) + audio(side) -> audio')
      expect(text).to match(/side\s+audio\s+port/)
      expect(text).to match(/space 0\.3 \(0\.\.1\)\s+:"dub\/space"/)
      expect(text).to include('latency 240 samples (5.0 ms at 48 kHz)')
      expect(text).to include('uses 1 use (in :bass)')
    end
  end

  describe 'printing' do
    it 'prints macros inside the rack block and round-trips through graph documents' do
      r = s.arack { |sig|
        cut = s.macro(:cut, 800, range: 100..8000, curve: :exp)
        sig.filter(:lowpass, cutoff: cut.mod(0.5.hz.lfo, depth: 0.1)) * s.macro(:space, 0.3) + sig * s.macro(:space)
      }
      g = 220.hz.ramp.then(&r)
      text = g.to_ruby
      expect(text).to include('macro(:cut, 800, range: 100..8000, curve: :exp).mod(0.5.hz.lfo, depth: 0.1)')
      expect(text).to include('macro(:space, 0.3)')

      doc = s::GraphIO.dump(g, name: 'macro_test')
      expect(doc).not_to match(/^knob /)
      g2 = s::GraphIO.load(doc)
      expect(s::GraphIO.dump(g2, name: 'macro_test').sub(/saved: "[^"]*"/, '')).to eq(doc.sub(/saved: "[^"]*"/, ''))
      expect(g2.sample(4800)).to eq(g.sample(4800))
    end
  end
end
