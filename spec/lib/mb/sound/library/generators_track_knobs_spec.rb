# Generator params as track knobs (gen-knobs-1; the maintainer,
# 2026-11-02: "Yes"): a generator's steering params the call leaves out
# become the track's knobs, :"drums/energy", rendering what the plain values
# render until turned.  (The library entries themselves: generators_spec.rb.)
RSpec.describe MB::Sound::Library::Generators, 'track knobs', :aggregate_failures do
  let(:lib) { MB::Sound::Library }
  let(:gens) { MB::Sound::Library::Generators }

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  # Cycles 0...n of +clip+'s events.
  def cycles(clip, n = 6)
    (0...n).map { |c| clip.events_for(c) }
  end

  # A Session that runs +setup+ in its context, then a scene playing
  # +track+'s clip, for +buffers+ buffers; returns [session, left].
  def run(track, setup, buffers: 60)
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) {
      setup.call
      MB::Sound.scene(:a, track => :on)
      MB::Sound.go(:a, on: :now)
    }
    buffers.times { s.process_buffer }
    [s, Numo::DFloat.cast(out.captured[0])]
  end

  # The shipped entries with steering params, and those params.
  GEN_KNOB_ENTRIES = {
    ambient_motif: %i[density mutate], ambient_figure: %i[density mutate], techno_beat: %i[energy],
    acid_rhythm: %i[energy], phrygian_motif: %i[density mutate], blur_cloud: %i[chance],
  }.freeze

  it 'are the ranged params that steer, named per track, apart from the instruments\' knobs' do
    got = MB::Sound::L.gen.entries.to_h { |e| [e.name, gens.knob_params(e)] }.reject { |_, v| v.empty? }
    expect(got).to eq(GEN_KNOB_ENTRIES)
    expect(MB::Sound::Arrangement::TrackKnobs.entry_params(MB::Sound::L.gen.techno_beat)).to eq(%i[energy])
    got.each do |name, ks|
      inst = MB::Sound::Arrangement::InstrumentPatch.entry_for(lib.index.lookup(:generator, name).settings[:instrument], track: :x)
      expect(ks & inst.params.keys).to eq([]), "#{name}'s knobs share names with #{inst.name}'s"
    end
    s, _ = run(:d2, -> {
      MB::Sound.track(:drums, MB::Sound::L.gen.techno_beat(energy: 0.8))
      MB::Sound.track(:d2, MB::Sound::L.gen.techno_beat)
      MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif(mutate: 0.3))
    }, buffers: 1)
    expect(s.knobs.keys.grep(%r{/(energy|density|mutate)\z})).to contain_exactly(:"d2/energy", :"lead/density")
    k = s.knobs[:"lead/density"]
    expect([k.value, k.spec.range, k.spec.param.description]).to eq([0.5, 0.0..1.0, gens::DESCRIPTIONS[:density]])
    expect(s.arrangement.tracks[:lead].clip.to_ruby).to eq('L.gen.phrygian_motif(seed: 7, mutate: 0.3)')
    expect(gens.knobs_of(s.arrangement.tracks[:lead].clip).transform_values(&:name)).to eq({ density: :"lead/density" })
    expect(gens.knobs_of(s.arrangement.tracks[:drums].clip)).to be_nil
  end

  it 'steer each entry at its defaults exactly as the plain values, cycle for cycle (the steered path)' do
    s = MB::Sound::Session.new(realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) do
      GEN_KNOB_ENTRIES.each do |name, ks|
        entry = lib.index.lookup(:generator, name)
        plain = entry.call(**ks.to_h { |k| [k, entry.params[k].default] })
        steered = gens.track_clip(entry, name, s)
        expect(steered).to be_steered
        expect(plain).not_to be_steered
        expect(gens.knobs_of(steered).keys).to eq(ks)
        n = name == :blur_cloud ? 3 : 16
        expect(cycles(steered, n)).to eq(cycles(plain, n)), name.to_s
      end
    end
  end

  # (each 2.5 s; the cycle example above covers 16 cycles)
  GEN_KNOB_ENTRIES.each do |name, ks|
    it "render #{name} on a track bit for bit with its knobs (#{ks.join(', ')}) and with the plain defaults" do
      entry = lib.index.lookup(:generator, name)
      s, got = run(:t, -> { MB::Sound.track(:t, entry) }, buffers: 150)
      expect(s.knobs.keys).to include(*ks.map { |k| :"t/#{k}" })
      _, ref = run(:t, -> { MB::Sound.track(:t, entry.call(**ks.to_h { |k| [k, entry.params[k].default] })) }, buffers: 150)
      expect(got.abs.max).to be > 0.001
      expect(got).to eq(ref)
    end
  end

  it 'turn: a knob at 0.9 renders what energy: 0.9 renders' do
    turned = -> { MB::Sound.track(:t, MB::Sound::L.gen.techno_beat); MB::Sound.turn(:"t/energy", 0.9) }
    s, got = run(:t, turned, buffers: 150)
    expect(s.knobs[:"t/energy"].value).to eq(0.9)
    _, ref = run(:t, -> { MB::Sound.track(:t, MB::Sound::L.gen.techno_beat(energy: 0.9)) }, buffers: 150)
    _, plain = run(:t, -> { MB::Sound.track(:t, MB::Sound::L.gen.techno_beat) }, buffers: 150)
    expect(got).to eq(ref)
    expect(got).not_to eq(plain)
  end

  it 'scenes, bg, and swap on a track give its knobs; the same call on the same track is one clip; scenes leave knobs as they are' do
    s, _ = run(:lead, -> {
      MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif)
      MB::Sound.scene(:same, lead: MB::Sound::L.gen.phrygian_motif)
      MB::Sound.scene(:three, lead: MB::Sound::L.gen.phrygian_motif(seed: 3))
    }, buffers: 1)
    arr = s.arrangement
    expect(arr.scenes[:same].values[:lead]).to equal(arr.tracks[:lead].clip)
    three = arr.scenes[:three].values[:lead]
    expect(three.to_ruby).to eq('L.gen.phrygian_motif(seed: 3)')
    expect(gens.knobs_of(three)[:density]).to equal(s.knobs[:"lead/density"])
    s.knobs[:"lead/density"].set(0.8, frame: s.knobs[:"lead/density"].next_frame)
    s.process_buffer
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.scene(:amb, lead: MB::Sound::L.gen.ambient_motif) # (its default 0.1: the knob stays where it is)
      expect(s.knobs[:"lead/density"].value).to eq(0.8)
      expect(gens.knobs_of(arr.scenes[:amb].values[:lead])[:density]).to equal(s.knobs[:"lead/density"])
      MB::Sound.bg(:lead, MB::Sound::L.gen.phrygian_motif(seed: 4), on: :now)
      MB::Sound.bg(:lead, MB::Sound::L.gen.ambient_figure, on: :now)
    }
    s.process_buffer
    expect(arr.tracks[:lead].clip.to_ruby).to eq('L.gen.ambient_figure(seed: 3)')
    expect(gens.knobs_of(arr.tracks[:lead].clip).transform_values(&:name)).to eq({ density: :"lead/density", mutate: :"lead/mutate" })
    MB::Sound::Session.with_context(session: s) { MB::Sound.swap(:lead, MB::Sound::L.gen.phrygian_motif(seed: 5)) }
    2.times { s.process_buffer }
    expect(arr.tracks[:lead].clip.to_ruby).to eq('L.gen.phrygian_motif(seed: 5)')
    expect(gens.knobs_of(arr.tracks[:lead].clip)).to include(:density)
  end

  it 'save in set documents as the calls, the knobs as knob lines, and load back steered' do
    s, _ = run(:drums, -> {
      MB::Sound.track(:drums, MB::Sound::L.gen.techno_beat)
      MB::Sound.scene(:b, drums: MB::Sound::L.gen.techno_beat(seed: 3))
      MB::Sound.knob(:"drums/energy").set(0.7, frame: 0)
    }, buffers: 1)
    text = MB::Sound::GraphIO.dump(s.arrangement, name: 'g')
    expect(text).to include('knob :"drums/energy", (0.0..1.0).at(0.7)', '= L.gen.techno_beat(seed: 3)', 'scene :b, drums: ')
    s2 = MB::Sound::Session.new(realtime: false)
    @sessions << s2
    MB::Sound::Session.with_context(session: s2) { MB::Sound::GraphIO.load(text) }
    expect(s2.knobs[:"drums/energy"].value).to eq(0.7)
    clip = s2.arrangement.scenes[:b].values[:drums]
    expect(gens.knobs_of(clip)[:energy]).to equal(s2.knobs[:"drums/energy"])
    expect(MB::Sound::GraphIO.dump(s2.arrangement, name: 'g').sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
  end

  it 'save a track\'s clip with its turned values as params, steered on a track again' do
    dir = File.dirname(tmp_path('presets/x'))
    ENV['MB_SOUND_PRESETS'] = dir
    lib.reload!
    s, _ = run(:lead, -> { MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif(seed: 2)) }, buffers: 1)
    s.knobs[:"lead/density"].set(0.75, frame: s.knobs[:"lead/density"].next_frame)
    s.process_buffer
    path = nil
    MB::Sound::Session.with_context(session: s) {
      expect { path = MB::Sound.save(:busy_motif, s.arrangement.tracks[:lead].clip) }.to output(/Saved busy_motif/).to_stdout
    }
    text = File.read(path)
    expect(text).to include('param :density, (0.0..1.0).at(0.75)', 'param :mutate, (0.0..1.0).at(0.15)',
                            'L.gen.phrygian_motif(seed: 2, density: density, mutate: mutate)')
    e = MB::Sound::L.gen.busy_motif
    expect(gens.knob_params(e)).to eq(%i[density mutate])
    expect(cycles(e.call, 8)).to eq(cycles(MB::Sound::L.gen.phrygian_motif(seed: 2, density: 0.75), 8))
    s2, _ = run(:x, -> { MB::Sound.track(:x, e) }, buffers: 1)
    expect(s2.knobs[:"x/density"].value).to eq(0.75)
  ensure
    ENV.delete('MB_SOUND_PRESETS')
    lib.reload!
  end
end
