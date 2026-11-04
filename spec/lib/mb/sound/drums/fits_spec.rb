# The fitted kit designs (Drums::Fits): the 909 kick fitted to a recorded
# TR-909 house beat (kick-lib-1, the maintainer's round-4 pick: "I like the
# round 3 kick -- save it to the library"), as a library kit entry, a
# design kit blocks borrow, and ranged voice knobs.
RSpec.describe(MB::Sound::Drums::Fits, :aggregate_failures) do
  let(:sound) { MB::Sound }
  let(:entry) { MB::Sound::L.kit.fit909_kick }
  let(:four) { MB::Sound.grid(16, kick: 'X...X...X...X...') }

  # The samples of +node+ until it ends (at most +seconds+), read in
  # +buffer+-frame buffers.
  def collect(node, seconds: 3, buffer: 800)
    out = []
    total = 0
    while total < seconds * 48000 && (buf = node.sample(buffer))
      out << buf.dup
      total += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  # The round 3 structure fit as the Bench printed it (the maintainer's
  # console code): what the library entry must play.
  def fitted_code(source)
    MB::Sound.kit(source, seed: 1) { voice(:kick) { |h| body = h.body(51.328155, decay: 0.468972, sweep: 2.061796, sweep_time: 0.08, drop: 0.283811, drop_time: 0.037723); d = 2.460364; h.mix((body * d).softclip(0.205115, 1.0) * (1.25 / (1 + 0.25 * d)), h.click(0.732949, tone: 0.090532), h.noise(decay: 0.035986, highpass: 482.059, lowpass: 4882.476) * 0.562526) } }
  end

  it 'plays bit for bit like the fit it was saved from, as an entry, borrowed, and as the design' do
    ref = collect(fitted_code(four))
    expect(ref.length).to be > 96000 # (four beats and the last one's ring)
    expect(ref.abs.max).to be > 0.5
    [
      entry.(four, seed: 1),
      MB::Sound.kit(four, seed: 1) { borrow :fit909_kick },
      MB::Sound.kit(four, seed: 1) { borrow MB::Sound::L.kit.fit909_kick },
      described_class.fit909_kick.kit(four, seed: 1),
      MB::Sound.kit(four, seed: 1) { borrow :fit909_kick; tr909 except: :kick },
    ].each_with_index do |k, i|
      got = collect(k)
      expect(got.length).to eq(ref.length), "case #{i}"
      expect((got - ref).abs.max).to eq(0), "case #{i}"
    end

    # A knob changes it (the knobs are the fit's numbers)
    moved = collect(entry.(four, seed: 1, kick: { decay: 0.8 }))
    n = [moved.length, ref.length].min
    expect((moved[0...n] - ref[0...n]).abs.max).to be > 0.01
  end

  it 'is a kit entry with tags, an about line, ranged params, and a code form' do
    expect(entry).to be_a(MB::Sound::Library::Entry)
    expect(entry.kind).to eq(:kit)
    expect(entry.family).to eq(:machine)
    expect(entry.tags).to include(:'909', :kick, :house, :techno)
    expect(entry.about).to match(/fitted/i)
    expect(entry.head_path).to eq('L.kit.fit909_kick')
    expect(entry.to_ruby).to eq("kit(grid(16, kick: 'x...x...').loop) { borrow :fit909_kick }")
    expect(entry.location).to match(%r{\Alib/mb/sound/drums/fits\.rb:\d+\z})

    params = entry.params
    expect(params.keys).to eq(%i[kick_tune kick_decay kick_punch kick_drop kick_drive kick_attack kick_tick])
    expect(params[:kick_tune].default).to eq(51.328155)
    expect(params[:kick_tune].range).to eq(30.0..110.0)
    expect(params[:kick_decay].default).to eq(0.468972)
    params.each_value { |prm| expect(prm.range).to cover(prm.default), prm.name.inspect }

    # The knobs read as on the tr909's kick: the fitted numbers through its
    # formulas, exactly
    knobs = described_class.fit909_kick.voices[:kick].defaults
    expect(knobs[:punch] * 5).to eq(2.061796)
    expect(MB::Sound::Drums.exp2(knobs[:drive] * 2)).to eq(2.460364)
    expect(knobs[:attack] * 0.9).to eq(0.732949)
    expect(knobs.keys).to eq(%i[level tune decay punch drop drive attack tick])

    # Songs pin it by its definition (a refit warns them; tr909 has none)
    expect(MB::Sound::Library::Pins.fingerprint(entry)).to match(/\A\h{16}\z/)
    expect(MB::Sound::Library::Pins.fingerprint_text(entry)).to include('def fit909_kick', '0.205115')

    # find and the heads see it
    expect(MB::Sound::Library.index.find('909 kick').hits.map(&:entry)).to include(entry)
    expect(MB::Sound::L.kit[:kick].entries).to include(entry)
  end

  it 'records, saves, and loads as kit { borrow :fit909_kick }' do
    k = entry.(four, seed: 1)
    expect(k.to_ruby).to include('kit(grid(16, kick: "X...X...X...X..."), name: :fit909_kick, seed: 1) { borrow :fit909_kick }')
    text = MB::Sound::GraphIO.dump(k)
    loaded = MB::Sound::GraphIO.load(text)
    expect((collect(loaded) - collect(fitted_code(four))).abs.max).to eq(0)
  end

  it 'auditions as its own row of the demo beat, and gets Bench beats' do
    expect(MB::Sound::Library::Audition.kit_rows(entry, MB::Sound::Library::Audition::KIT_DEMO)).to eq(kick: 'x...x...x...x...')
    expect(MB::Sound::Library::Audition.kit_rows(MB::Sound::L.kit.tr909, MB::Sound::Library::Audition::KIT_DEMO)).to eq(MB::Sound::Library::Audition::KIT_DEMO)
    play = MB::Sound::Library::Audition.playable(entry)
    expect(play.description).to eq('L.kit.fit909_kick playing a beat')
    out = collect(play.nodes.first, seconds: 1)
    expect(out.abs.max).to be > 0.1

    mats = MB::Sound::Library::Bench.materials_for(entry)
    expect(mats.map(&:key)).to include(:drums_beat, :drums_busy)
    mats.each { |m| expect(m.source.call.rows.keys).to eq([:kick]), m.key.inspect if m.key.to_s.start_with?('drums') }
  end

  describe 'Builder#borrow and except:' do
    it 'puts the fitted kick in a 909 without moving the other voices' do
      beat = MB::Sound.grid(16, kick: 'X...X...X...X...', clap: '....X.......X...', hat: 'x.xxx.xxx.xxx.xx')
      mine = MB::Sound.kit(beat, seed: 3, outputs: :separate) { borrow :fit909_kick; tr909 except: :kick }
      theirs = MB::Sound.tr909(beat, seed: 3, outputs: :separate)
      expect(mine.names).to eq(theirs.names)
      a = mine.channels.map { |c| collect(c, seconds: 1) }
      b = theirs.channels.map { |c| collect(c, seconds: 1) }
      mine.names.each_with_index do |n, i|
        next if n == :kick
        expect((a[i] - b[i]).abs.max).to eq(0), n.inspect
      end
      kick = mine.names.index(:kick)
      expect((a[kick] - b[kick]).abs.max).to be > 0.01
    end

    it 'says how to leave a voice out, and names the designs' do
      expect { MB::Sound.kit { tr909; borrow :fit909_kick } }.to raise_error(ArgumentError, /already has a :kick voice.*except: :kick/)
      expect { MB::Sound.kit { borrow :fit909_kik } }.to raise_error(ArgumentError, /No kit design :fit909_kik.*Did you mean\?  :fit909_kick/m)
      expect { MB::Sound.kit { tr909 except: :zap } }.to raise_error(ArgumentError, /Unknown tr909 voice :zap/)
      m = MB::Sound.kit { tr808 :kick, :snare, except: :kick }
      expect(m.names).to eq([:snare])
      expect(MB::Sound.kit { borrow :tr909, except: %i[kick snare] }.names).not_to include(:kick, :snare)
    end
  end

  describe 'ranged voice knobs' do
    it 'reads the default and keeps the range as a Param' do
      m = MB::Sound.kit { voice(:zap, pitch: (100.0..900.0).at(440.0)) { |h| h.body(h.pitch, decay: 0.1) } }
      spec = m.voices[:zap]
      expect(spec.defaults[:pitch]).to eq(440.0)
      expect(spec.params[:pitch]).to be_a(MB::Sound::Param)
      expect(spec.params[:pitch].range).to eq(100.0..900.0)
      k = m.kit(m.grid(16, zap: 'x...'))
      expect(k.voices[:zap].knob_params[:pitch].range).to eq(100.0..900.0)
      expect(k.voices[:zap].knobs[:pitch]).to eq(440.0)
      # (borrowed voices keep their ranges)
      expect(MB::Sound.kit { borrow m }.voices[:zap].params.keys).to eq([:pitch])
    end
  end
end
