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

  # +x+ through a 2 x 2-pole band filter (nil for no edge), as DFloat.
  def band(x, lo, hi)
    f = []
    2.times { f << MB::Sound::Filter::Cookbook.new(:highpass, 48000, lo, quality: 0.7) } if lo
    2.times { f << MB::Sound::Filter::Cookbook.new(:lowpass, 48000, hi, quality: 0.7) } if hi
    Numo::DFloat.cast(MB::Sound::Filter::FilterChain.new(*f).process(Numo::SFloat.cast(x)))
  end

  # RMS level in dB of +x+ from +t0+ to +t1+ seconds.
  def level(x, t0, t1)
    10 * Math.log10((x[(t0 * 48000).to_i...(t1 * 48000).to_i]**2).mean + 1e-30)
  end

  # boom-2 (the maintainer on boom-1's tails: "Too metallic and wobbly",
  # "almost gong like"): the tail is a library reverb preset; boom-1's
  # room-size form (8 lines, subtle modulation) rang as separate modes
  # under its 8 s decay
  it 'rings its tail through a library reverb preset, smoother than the room-size form' do
    imp = Numo::SFloat.zeros(300 * 800)
    imp[0] = 1
    s = described_class.settings(:cinematic).merge(tail: 1, width: 1, tail_length: 4.0)
    flat = %i[space room_size].to_h { |r|
      out = samples(described_class.tail(MB::Sound::ArrayInput.new(data: [imp]), s.merge(reverb: r)), 300)
      [r, MB::Sound::Analysis::ImpulseResponse.new(out.map { |c| c - Numo::DFloat.cast(imp) }).tail_flatness]
    }
    expect(flat[:space].min).to be > 0.3 # (0.56 for noise; :space reads about 0.45)
    expect(flat[:room_size].max).to be < 0.15 # (boom-1's: about 0.03)
    expect(described_class.settings(:cinematic)[:reverb]).to eq(:space)
    expect(described_class.settings(:impact)[:reverb]).to eq(:room)

    described_class::REVERBS.each do |r|
      MB::Sound.seed(1)
      out = samples(MB::Sound.boom(MB::Sound::G1, :impact, reverb: r), 30)
      expect(out.length).to eq(2)
      expect(out[0].abs.max).to be > 0.1
    end
    expect { MB::Sound.boom(MB::Sound::G1, reverb: :stadium) }.to raise_error(ArgumentError, /stadium/)
  end

  it 'cuts the lows inside its tail with tail_cut' do
    MB::Sound.seed(1)
    dry = samples(MB::Sound.boom(MB::Sound::G1, tail: 0), 180)[0]
    wet = { 0 => nil, 100 => nil }.to_h { |cut, _|
      MB::Sound.seed(1)
      out = samples(MB::Sound.boom(MB::Sound::G1, tail_cut: cut), 180)
      [cut, band((out[0] + out[1]) / 2 - dry, nil, 100)]
    }
    expect(level(wet[100], 1, 3)).to be < level(wet[0], 1, 3) - 10
  end

  # boom-2 (the maintainer on boom-1's :sub_drop: "continued down and
  # faded out below say 30Hz")
  it 'falls through the note and fades out under the floor (below, floor)' do
    MB::Sound.seed(1)
    held = samples(MB::Sound.boom(MB::Sound::E1, :sub_drop, tail: 0, below: 0, floor: 0), 240)[0]
    MB::Sound.seed(1)
    drop = samples(MB::Sound.boom(MB::Sound::E1, :sub_drop, tail: 0), 240)[0]
    expect(pitch_at(held, 2.5)).to be_within(1).of(MB::Sound::E1.frequency)
    expect(pitch_at(drop, 1.6)).to be < 0.8 * MB::Sound::E1.frequency
    peak = drop.abs.max
    expect(level(drop, 2.4, 3.0)).to be < 20 * Math.log10(peak) - 60
    expect(level(held, 2.4, 3.0)).to be > 20 * Math.log10(peak) - 30

    # (below: 0 and floor: 0 play the boom-1 voice)
    MB::Sound.seed(1)
    a = samples(MB::Sound.boom(MB::Sound::G1, :trailer, tail: 0), 30)[0]
    MB::Sound.seed(1)
    b = samples(MB::Sound.boom(MB::Sound::G1, :trailer, tail: 0, below: 0, floor: 0), 30)[0]
    expect(a).to eq(b)
  end

  # The level of +x+ in the 600-2400 Hz band over the 150-600 Hz band (dB)
  # from +t0+ to +t1+ seconds: lower is darker.
  def tilt(x, t0, t1)
    level(band(x, 600, 2400), t0, t1) - level(band(x, 150, 600), t0, t1)
  end

  # The pitch of +x+ in Hz around +t+ seconds (zero crossings within
  # +half+ seconds either side; for the sub drop's slow end).
  def pitch_around(x, t, half = 0.1)
    seg = x[((t - half) * 48000).to_i...((t + half) * 48000).to_i]
    zc = (1...seg.size).select { |k| seg[k - 1] < 0 && seg[k] >= 0 }
    (zc.length - 1) * 48000.0 / (zc[-1] - zc[0])
  end

  # boom-3 (the maintainer on boom-2's tails: "Too much noise in the tail.
  # I'd want more damping with the apparent frequency of the tail decaying
  # over time."): the rumble's lowpass falls as it fades (rumble_fall), and
  # tail_tone puts a lowpass inside the reverb, so the tail can darken as
  # it decays instead of keeping one spectrum
  it 'darkens its rumble and tail as they decay with rumble_fall and tail_tone' do
    mono = ->(o) { (o[0] + o[1]) / 2 }

    # The rumble alone: its lowpass falls 2 octaves over rumble_decay
    rumble = { 0 => nil, 2 => nil }.to_h { |fall, _|
      MB::Sound.seed(1)
      [fall, samples(MB::Sound.boom(MB::Sound::G1, tail: 0, click: 0, punch: 0, decay: 0.05, drive: 0, rumble_fall: fall), 240)[0]]
    }
    expect(tilt(rumble[2], 3, 4)).to be < tilt(rumble[2], 0.2, 0.7) - 6
    expect((tilt(rumble[0], 3, 4) - tilt(rumble[0], 0.2, 0.7)).abs).to be < 3

    # tail_tone: a lowpass inside the reverb in place of damping
    dry = samples(MB::Sound.boom(MB::Sound::G1, tail: 0, rumble: 0), 180)[0]
    wet = { 0 => nil, 800 => nil }.to_h { |tone, _|
      out = samples(MB::Sound.boom(MB::Sound::G1, rumble: 0, damping: 0, tail_tone: tone), 180)
      [tone, mono.(out) - dry]
    }
    expect(level(band(wet[800], 600, 2400), 1, 2)).to be < level(band(wet[0], 600, 2400), 1, 2) - 10
  end

  # boom-3 (the maintainer on :sub_drop: "slowing the pitch curve, so the
  # pitch velocity gets close to (but not equal to) zero around
  # 25Hz/fadeout"): sweep_curve is the fall's ease-out (Curve.db), so a
  # higher one settles toward where below lands as the floor fades it out
  it 'slows its sub drop toward the fade with sweep_curve' do
    MB::Sound.seed(1)
    x = samples(MB::Sound.boom(MB::Sound::E1, :sub_drop, tail: 0, sweep: 4.5, sweep_curve: 30, below: 1.04, floor: 40), 240)[0]
    f = [1.5, 2.0, 2.5, 3.0].map { |t| pitch_around(x, t) }
    expect(f[2]).to be_between(24, 28)
    expect(f[3]).to be_between(21, 25.5)
    expect(Math.log2(f[2] / f[3])).to be < 0.6 * Math.log2(f[0] / f[1]) # (still falling, but slower)
    expect(f[3]).to be < f[2]
    expect(level(x, 3.4, 3.6)).to be < 20 * Math.log10(x.abs.max) - 60
  end

  it 'plays without its noise burst by default, with it as a setting' do
    hi = %i[off on].to_h { |k|
      MB::Sound.seed(1)
      out = samples(MB::Sound.boom(MB::Sound::G1, tail: 0, **(k == :on ? { noise: 0.061 } : {})), 120)[0]
      [k, level(band(out, 8000, nil), 0.5, 1.5)]
    }
    expect(described_class.settings(:cinematic)[:noise]).to eq(0)
    expect(hi[:on]).to be > hi[:off] + 10
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
