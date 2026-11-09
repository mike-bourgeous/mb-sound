require 'tmpdir'

# Cinematic booms (boom-1): Boom presets played from notes (`boom(clip,
# :trailer)`, L.inst.boom.trailer), as one-shots (`boom(G1)`,
# `L.inst.boom.trailer.ping`), as kit pieces (`h.boom(:impact)`), and on
# tracks with their settings as knobs.
RSpec.describe(MB::Sound::Boom, :aggregate_failures) do
  HITS = MB::Sound.seq(MB::Sound::G1, MB::Sound::R, MB::Sound::E1, MB::Sound::R).n2

  after { MB::Sound.rewind }

  # +node+'s first +buffers+ buffers (every output), as DFloats.
  def samples(node, buffers = 60)
    outs = node.respond_to?(:channel_count) && node.channel_count > 1 ? node.outputs : [node]
    data = outs.map { [] }
    buffers.times { outs.each_with_index { |o, i| (b = o.sample(800)) && data[i] << b.dup } }
    data.map { |d| SpecBuffers.join(d) }
  end

  # The pitch of +x+ in Hz around +t+ seconds (zero crossings over 40 ms,
  # lowpassed at 400 Hz).
  def pitch_at(x, t)
    lp = MB::Sound::Filter::FilterChain.new(*4.times.map { MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 400, quality: 0.7) })
    y = lp.process(Numo::SFloat.cast(x[0...((t + 0.05) * 48000).to_i]))[(t * 48000).to_i..]
    zc = (1...y.size).select { |k| y[k - 1] < 0 && y[k] >= 0 }
    (zc.length - 1) * 48000.0 / (zc[-1] - zc[0])
  end

  it 'has entries for its presets, with Params for every setting' do
    names = described_class.preset_names
    expect(names).to include(:cinematic, :sub_drop, :impact, :trailer)
    expect(MB::Sound::L.inst.boom.names).to match_array(names)
    e = MB::Sound::L.inst.boom.trailer
    expect(e).to have_attributes(kind: :instrument, family: :boom)
    expect(e.to_ruby).to eq('boom(midi, :trailer)')
    expect(e.params.keys).to match_array(described_class.preset_params.keys)
    names.each do |name|
      described_class.preset_entry(name).params.each_value do |p|
        expect(p.description).to be_a(String)
        expect(p.check(p.default)).to eq(p.default) # (every preset value inside its range)
      end
    end
    expect(described_class.preset_params[:decay].curve).to eq(:exp)
    expect { MB::Sound.boom(HITS, :trailr) }.to raise_error(ArgumentError, /Unknown boom preset :trailr.*Did you mean\?.*:trailer/m)
  end

  it 'plays from notes: the body falls onto each note, as hard as its velocity' do
    MB::Sound.seed(1)
    out = samples(MB::Sound.boom(MB::Sound.seq(MB::Sound::G1.n1, MB::Sound::E1.n1), tail: 0), 240)[0] # (dry: mono)
    expect(out.abs.max).to be_between(0.5, 3.0) # (presets are at -20.3 LUFS through the -10 dB master, or peak at -3 dBFS there)
    expect(pitch_at(out, 0.5)).to be_within(1.5).of(MB::Sound::G1.frequency)
    expect(pitch_at(out, 2.5)).to be_within(1.5).of(MB::Sound::E1.frequency)
    expect(pitch_at(out, 2.0)).to be > 1.5 * MB::Sound::E1.frequency # (the strike starts octaves up)

    # Velocity: level, and with vel_depth the drop
    MB::Sound.seed(1)
    soft = samples(MB::Sound.boom(MB::Sound.seq(MB::Sound::G1.n1).vel(0.5), tail: 0), 60)[0]
    MB::Sound.seed(1)
    hard = samples(MB::Sound.boom(MB::Sound.seq(MB::Sound::G1.n1).vel(1.0), tail: 0), 60)[0]
    expect(hard[0...24000].abs.max).to be > 1.5 * soft[0...24000].abs.max
    expect(pitch_at(hard, 0.003)).to be > pitch_at(soft, 0.003)

    # Note lengths don't matter (one hit per note)
    MB::Sound.seed(1)
    long = samples(MB::Sound.boom(MB::Sound.seq(MB::Sound::G1.n1).legato(1.0), tail: 0), 60)[0]
    MB::Sound.seed(1)
    short = samples(MB::Sound.boom(MB::Sound.seq(MB::Sound::G1.n32), tail: 0), 60)[0]
    expect(long).to eq(short)
  end

  it 'hits once from a pitch or an entry, and the graph ends' do
    g = MB::Sound.boom(MB::Sound::G1, :impact)
    out = samples(g, 120)
    expect(out.length).to eq(2) # (the reverb tail is stereo)
    expect(out[0].abs.max).to be > 0.1
    expect((1..3000).find { g.outputs.map { |o| o.sample(800) }.compact.empty? }).not_to be_nil

    expect(samples(MB::Sound.boom(:trailer, MB::Sound::E1), 10)[0].abs.max).to be > 0.05
    expect(samples(MB::Sound::L.inst.boom.impact.ping, 10)[0].abs.max).to be > 0.05
    expect(samples(MB::Sound::L.inst.boom.impact.ping(MB::Sound::E1), 10)[0].abs.max).to be > 0.05
    expect(described_class.home_note(:cinematic).name).to eq('G1')
    expect(MB::Sound::Playable.graph(MB::Sound::L.inst.boom.impact).description).to eq('L.inst.impact hit once (at A1)')
    expect { MB::Sound::L.inst.boom.impact.ping(MB::Sound::G1, HITS) }.to raise_error(ArgumentError, /ping takes pitches/)
  end

  it 'plays in kits without its tail' do
    beat = MB::Sound.grid(16, kick: 'x...............')
    MB::Sound.seed(1)
    k = MB::Sound.kit(beat) { voice(:kick) { |h| h.boom(:impact) } }
    out = samples(k, 60)[0]
    expect(out.abs.max).to be > 0.1
    expect(pitch_at(out, 0.3)).to be_within(1.5).of(described_class.home_note(:impact).frequency)
    MB::Sound.seed(1)
    up = samples(MB::Sound.kit(beat) { voice(:kick) { |h| h.boom(:impact, tune: MB::Sound::C2) } }, 60)[0]
    expect(pitch_at(up, 0.3)).to be_within(1.5).of(MB::Sound::C2.frequency)
  end

  it 'records, saves, and loads as written' do
    g = MB::Sound.boom(HITS, :trailer, decay: 5)
    expect(g.to_ruby(inputs: { midi: HITS })).to include('boom(midi, :trailer, decay: 5')
    expect(MB::Sound.cinematic_boom(HITS).to_ruby(inputs: { midi: HITS })).to include('boom(midi')

    MB::Sound.seed(3)
    g = MB::Sound.boom(HITS, :trailer, decay: 5)
    doc = MB::Sound::GraphIO.dump(g, inputs: { midi: HITS })
    expect(doc).to match(/boom\(midi, :trailer, decay: 5, seed: drawn_seed\(\d+\)\)/)
    MB::Sound.seed(3)
    a = samples(MB::Sound.boom(HITS, :trailer, decay: 5))
    MB::Sound.seed(9) # (the document gives the drawn seed back)
    b = samples(MB::Sound::GraphIO.load(doc, inputs: { midi: HITS }))
    expect(b).to eq(a)

    # Recipes: the kit piece prints as its Hit call
    k = MB::Sound.kit(MB::Sound.grid(16, kick: 'x...').loop) { voice(:kick) { |h| h.boom(:impact) } }
    expect(MB::Sound::GraphIO.dump(k)).to include('h.boom(:impact)')
  end

  it 'plays on a track with its settings as knobs, the same samples while untouched' do
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.seed(2)
      MB::Sound.track(:fx, HITS, MB::Sound::L.inst.boom.impact)
      expect(s.knobs[:"fx/decay"].value).to eq(MB::Sound::L.inst.boom.impact.params[:decay].default)
      expect(s.knobs.keys).to include(:"fx/drop", :"fx/click", :"fx/tail")
      expect(s.knobs.keys).not_to include(:"fx/note", :"fx/voices", :"fx/level", :"fx/room")
      MB::Sound.bg(:fx, HITS)
    end
    120.times { s.process_buffer }
    expect(Numo::DFloat.cast(out.captured[0]).abs.max).to be > 0.05
  ensure
    s&.close
  end

  it 'plays the same with knobs at its settings as with the numbers' do
    params = described_class.preset_entry(:trailer).params
    knobs = MB::Sound::Boom::KNOB_PARAMS.to_h { |k| [k, MB::Sound::GraphNode::Knob.new(k, params[k].default, range: params[k].range)] }
    MB::Sound.seed(4)
    a = samples(MB::Sound.boom(HITS, :trailer), 120)
    MB::Sound.seed(4)
    b = samples(MB::Sound.boom(HITS, :trailer, **knobs), 120)
    # (knobs are float32 values: about -117 dBFS apart from the numbers, as
    # library.md's preset knobs that read through a knob)
    a.zip(b).each { |x, y| expect((x - y).abs.max).to be < 1e-5 }
    expect(a[0].abs.max).to be > 0.1
  end

  it 'comes from library files' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'booms.rb'), <<~RUBY)
        library 1
        boom :deep_hit, note: 28, drop: 3, decay: 4, tags: %i[deep]
      RUBY
      old = ENV['MB_SOUND_PRESETS']
      begin
        ENV['MB_SOUND_PRESETS'] = dir
        MB::Sound::Library.reload!
        e = MB::Sound::L.inst.deep_hit
        expect(e).to have_attributes(family: :boom, settings: { note: 28, drop: 3, decay: 4 })
        expect(e.params[:decay].default).to eq(4)
        MB::Sound.seed(1)
        x = samples(e.(HITS))
        MB::Sound.seed(1)
        y = samples(MB::Sound.boom(HITS, :cinematic, note: 28, drop: 3, decay: 4))
        expect(x).to eq(y)
        expect(described_class.home_note(:deep_hit).name).to eq('E1')
      ensure
        ENV['MB_SOUND_PRESETS'] = old
        MB::Sound::Library.reload!
      end
    end
  end

  # Levels: one hit at the default velocity at about -20.3 LUFS through the
  # default master (the library's instrument loudness), or its peak at -3
  # dBFS there when that comes first (:cinematic's click)
  MB::Sound::Boom.preset_names.each do |name|
    it "plays #{name} at about -20.3 LUFS, or peaking at -3 dBFS, through the default master" do
      MB::Sound.seed(0)
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
      MB::Sound.render(out, MB::Sound.boom(described_class.home_note(name), name), seconds: 12)
      data = out.captured.map { |c| Numo::DFloat.cast(c) }
      peak = 20 * Math.log10(data.map { |c| c.abs.max }.max)
      lufs = MB::Sound.loudness(data).integrated
      expect(peak).to be <= -2.5
      expect(lufs <= -19.3 && (lufs >= -21.3 || peak >= -3.5)).to eq(true), "#{name}: #{lufs.round(2)} LUFS, peak #{peak.round(2)} dBFS"
    end
  end
end
