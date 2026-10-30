require 'tmpdir'

# Struck instruments (library-instruments-1, item 4): every resonator
# effect preset played from notes (`struck(clip, :bar)`, L.inst.bar), built
# from the resonator preset by reference; resonator effects ping
# (`L.fx.bar.ping(C5)`, `play L.fx.bar`); tracks take them (L.fx.bell on a
# track plays L.inst.bell, its decay a knob); library files make more.
RSpec.describe(MB::Sound::Struck, :aggregate_failures) do
  PHRASE = MB::Sound.seq(MB::Sound::C5, MB::Sound::E5, MB::Sound::G5.n4, [MB::Sound::C5, MB::Sound::E5]).n8.loop

  after { MB::Sound.rewind }

  # +node+'s first +buffers+ buffers (every output), as DFloats.
  def samples(node, buffers = 60)
    outs = node.respond_to?(:channel_count) && node.channel_count > 1 ? node.outputs : [node]
    data = outs.map { [] }
    buffers.times { outs.each_with_index { |o, i| (b = o.sample(800)) && data[i] << b.dup } }
    data.map { |d| SpecBuffers.join(d) }
  end

  it 'has a struck instrument for every resonator preset, by reference' do
    res = MB::Sound::GraphNode::ModalResonator.presets
    res.each do |name, r|
      e = MB::Sound::Library.index.lookup(:struck, name, note: false)
      expect(e).to have_attributes(kind: :instrument, family: :struck, settings: { resonator: name }, tags: r.tags)
      expect(e.params[:decay].default).to eq(r.settings[:decay].to_f)
      expect(e.params[:beat].default).to eq(r.settings[:beat].to_f)
    end
    expect(MB::Sound::L.inst.bar).to equal(MB::Sound::Library.index.lookup(:struck, :bar, note: false))
    expect(MB::Sound::L.inst.struck.names).to match_array(res.keys)
    expect(MB::Sound::Library.index.lookup(:struck, :glockenspiel, note: false).name).to eq(:bar) # (the resonator's aliases)

    # The same samples as striking the resonator from a synth's notes
    MB::Sound.seed(1)
    a = samples(MB::Sound.struck(PHRASE, :bar, level: 1))
    MB::Sound.seed(1)
    b = samples(MB::Sound.synth(PHRASE, voices: 8) { |v| v.trigger.resonate(:bar, v.freq) })
    expect(a).to eq(b)
    expect(a[0].abs.max).to be > 0.05
    # (options and the level)
    MB::Sound.seed(1)
    c = samples(MB::Sound.struck(PHRASE, :bar, decay: 0.5, beat: 1.2, spread: 0.5))
    expect(c.length).to eq(2)
    expect(MB::Sound.struck(PHRASE, :bar).to_ruby(inputs: { midi: PHRASE })).to include('struck(midi, :bar)')
  end

  it 'pings resonator effects and plays entries' do
    g = MB::Sound::L.fx.bar.ping(MB::Sound::C5)
    out = samples(g, 200)[0]
    expect(out.abs.max).to be > 0.05
    expect((1..2000).find { g.sample(800).nil? }).not_to be_nil # (one strike, rung out: the graph ends)
    expect(samples(MB::Sound::L.fx.bell.ping(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4), 4)[0].abs.max).to be > 0.01
    expect(MB::Sound::Struck.home_note(:bar).name).to eq('A6')
    expect { MB::Sound::L.fx.hall.ping }.to raise_error(ArgumentError, /isn't a resonator: ping strikes resonators/)

    pl = MB::Sound::Playable
    expect(pl.graph(MB::Sound::L.fx.bar).description).to eq('L.fx.bar struck once (L.inst.bar at A6)')
    expect(pl.graph(MB::Sound::L.inst.bowl).description).to eq('L.inst.bowl playing a demo phrase')
    expect(pl.graph(MB::Sound::L.inst.dnb.dnb_sub).description).to eq('L.inst.dnb_sub playing a demo phrase')
    expect(pl.graph(MB::Sound::L.kit.tr909).description).to eq('L.kit.tr909 playing a beat')
    # (ui-scaffold-1: other effects play the demo phrase through them;
    # sample edits still say what they are)
    expect(pl.graph(MB::Sound::L.fx.hall).description).to eq('L.fx.hall on a demo phrase')
    expect { pl.graph(MB::Sound::L.edit.s950) }.to raise_error(pl::Unplayable, /sample_edit .*nothing to play by itself/)
  end

  it 'plays on a track from a resonator effect, its decay the track knob' do
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    MB::Sound::Session.with_context(session: s) do
      expect(MB::Sound.track(:bells, MB::Sound::L.fx.bell)).to eq(:bells)
      expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(s.arrangement.tracks[:bells].patch)).to equal(MB::Sound::L.inst.bell)
      expect(s.knobs[:"bells/decay"].value).to eq(MB::Sound::L.inst.bell.params[:decay].default)
      MB::Sound.bg(:bells, PHRASE)
    end
    60.times { s.process_buffer }
    expect(Numo::DFloat.cast(out.captured[0]).abs.max).to be > 0.01
    expect(MB::Sound::UI::Inspect::Gatherer.new.call(s, { track: :bells, node: nil }).knobs).to eq([:"bells/decay"])
  ensure
    s&.close
  end

  it 'saves in graph documents and comes from library files' do
    doc = MB::Sound::GraphIO.dump(MB::Sound.struck(PHRASE, :marimba, decay: 0.8), inputs: { midi: PHRASE })
    expect(doc).to include('struck(midi, :marimba, decay: 0.8)')
    MB::Sound.seed(1)
    a = samples(MB::Sound.struck(PHRASE, :marimba, decay: 0.8))
    MB::Sound.seed(1)
    b = samples(MB::Sound::GraphIO.load(doc, inputs: { midi: PHRASE }))
    expect(b).to eq(a)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bells.rb'), <<~RUBY)
        library 1
        struck :soft_bell, resonator: :bell, decay: 6, beat: 0.4, tags: %i[soft]
        instrument :bar_pair do |midi|
          struck(midi, :bar, decay: 1.5) + struck(midi, :marimba) * 0.5
        end
      RUBY
      old = ENV['MB_SOUND_PRESETS']
      begin
        ENV['MB_SOUND_PRESETS'] = dir
        MB::Sound::Library.reload!
        e = MB::Sound::L.inst.soft_bell
        expect(e).to have_attributes(family: :struck, settings: { resonator: :bell, decay: 6, beat: 0.4 })
        expect(e.params[:decay].default).to eq(6.0)
        MB::Sound.seed(1)
        x = samples(e.(PHRASE))
        MB::Sound.seed(1)
        y = samples(MB::Sound.struck(PHRASE, :bell, decay: 6, beat: 0.4)) # (the bell's level too)
        expect(x[0].abs.max).to be > 0.001
        expect(x).to eq(y)
        session = MB::Sound::Session.new(realtime: false)
        MB::Sound::Session.with_context(session: session) do
          expect(samples(MB::Sound::L.inst.bar_pair.(PHRASE), 10)[0].abs.max).to be > 0.001
        end
        session.close
      ensure
        ENV['MB_SOUND_PRESETS'] = old
        MB::Sound::Library.reload!
      end
    end
  end

  # Levels: about -20.3 LUFS through the default master on Struck.phrase
  # (the membrane's peak caps it lower: below full scale)
  MB::Sound::GraphNode::ModalResonator.presets.keys.each do |name|
    it "plays #{name} at about -20.3 LUFS on its phrase" do
      MB::Sound.seed(1)
      phrase = described_class.phrase(name)
      clip = phrase | phrase | phrase | phrase
      MB::Sound.bpm(100)
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
      MB::Sound.render(out, MB::Sound.struck(clip, name), bars: 4)
      data = out.captured.map { |c| Numo::SFloat.cast(c) }
      if name == :membrane
        expect(data.map { |c| c.abs.max }.max).to be_between(0.5, 0.9)
      else
        expect(MB::Sound.loudness(data).integrated).to be_within(1).of(-20.3)
      end
    ensure
      MB::Sound.bpm(120)
    end
  end
end
