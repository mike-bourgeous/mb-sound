RSpec.describe(MB::Sound::Mastering, :aggregate_failures) do
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session(**opts)
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true, **opts
    ).tap { |s| sessions << s }
  end

  def within(s, &block)
    MB::Sound::Session.with_context(session: s, &block)
  end

  # Runs +node+ (a bundle) in +size+-sample buffers for +total+ samples.
  def run(node, total, size)
    outs = node.outputs
    chunks = Array.new(outs.length) { [] }
    done = 0
    while done < total
      n = [size, total - done].min
      outs.each_with_index { |o, i| chunks[i] << o.sample(n).dup }
      done += n
    end
    chunks.map { |c| SpecBuffers.join(c) }
  end

  # A stereo test mix: a chord and a kick-like pulse.
  def test_mix(level: 0.3)
    MB::Sound.with_seed(4) {
      l = 110.hz.ramp.at(level) + 165.hz.saw.rnd.at(level * 0.6) + 55.hz.sine.at(level * 2) * 2.hz.aramp.abs
      r = 138.6.hz.ramp.rnd.at(level) + 220.hz.triangle.at(level * 0.6) + 55.hz.sine.at(level * 2) * 2.hz.aramp.abs
      MB::Sound::GraphNode::Channels.new([l, r])
    }
  end

  describe '.preset' do
    it 'makes the four presets with their targets and ceilings' do
      expect(described_class.names).to eq(%i[club streaming quiet vinyl])
      club = described_class.preset(:club)
      expect(club.target.lufs).to eq(-8.5)
      expect(club.ceiling.db_value).to eq(-0.5)
      expect(club.limiter).to eq(true)
      expect(club.steps.map(&:first)).to eq(%i[mono_below trim compress filter filter limit limit])
      expect(described_class.preset(:club, clip: true).steps.map(&:first)).to eq(%i[mono_below trim compress filter filter softclip limit])
      expect(club).to be_frozen
      expect(club.steps).to be_frozen

      apple = described_class.preset(:streaming, platform: :apple)
      expect(apple.target.lufs).to eq(-16)
      expect(apple.ceiling.db_value).to eq(-1)
      expect(described_class.preset(:streaming, lufs: :amazon).ceiling.db_value).to eq(-2)

      ebu = described_class.preset(:quiet, lufs: :ebu_r128)
      expect(ebu.target.lufs).to eq(-23)
      expect(ebu.steps.map(&:first)).to eq(%i[trim limit])

      vinyl = described_class.preset(:vinyl)
      expect(vinyl.limiter).to eq(false)
      expect(vinyl.ceiling.db_value).to eq(-1)
      expect(vinyl.steps.map(&:first)).to eq(%i[mono_below highpass trim compress de_ess])
    end

    it 'takes options that change the chain' do
      p = described_class.preset(:club, lufs: -9, ceiling: -1.db, clip: false, mono: false)
      expect(p.steps.map(&:first)).to eq(%i[trim compress filter filter limit limit])
      expect(p.steps.last[2][:ceiling].db_value).to eq(-1)
      expect(p.target.lufs).to eq(-9)
      expect(described_class.preset(:club, drive: 6.db).targeted?).to eq(false)
      expect(described_class.preset(:club, ride: true).ride).to eq(described_class::RIDE_DEFAULTS)
      expect(described_class.preset(p, glue: false).steps.map(&:first)).to eq(%i[trim filter filter limit limit])
    end

    it 'takes the club\'s air stage as an option' do
      expect(described_class.preset(:club, air: :dynamic).steps.map(&:first)).to include(:dynamic_air)
      expect(described_class.preset(:club, air: :band).steps.map(&:first)).to include(:air_band)
      expect(described_class.preset(:club, air: false).steps.map(&:first)).to eq(%i[mono_below trim compress limit limit])
      expect { described_class.preset(:club, air: :loud) }.to raise_error(ArgumentError, /air: is :static/)
      [:dynamic, :band].each do |air|
        out = run(test_mix(level: 0.6).master(:club, air: air), 24000, 800)
        a = MB::Sound::Loudness::Analyzer.new(channels: 2)
        a.process(out)
        expect(a.true_peak).to be <= -0.4
      end
    end

    it 'prints itself back as the call that makes it' do
      p = described_class.preset(:club, lufs: -9, ceiling: -1.db, ride: { up: 5 })
      expect(p.call_ruby).to eq(':club, lufs: -9, ceiling: -1.db, ride: { up: 5 }')
      expect(MB::Sound.module_eval(p.to_ruby)).to eq(p)
    end

    it 'explains unknown presets and options' do
      expect { described_class.preset(:clubb) }.to raise_error(ArgumentError, /Unknown mastering preset :clubb.*Did you mean\?  :club/m)
      expect { described_class.preset(:club, luf: -8) }.to raise_error(ArgumentError, /Unknown option :luf .*Did you mean\?  :lufs/m)
      expect { described_class.preset(:streaming, lufs: -14, platform: :apple) }.to raise_error(ArgumentError, /not both/)
      expect { described_class.preset(:club, ceiling: 1.db) }.to raise_error(ArgumentError, /at most 0 dBTP/)
    end

    it 'lists the presets from the console' do
      expect { expect(MB::Sound.masters).to eq(described_class.names) }.to output(/:club .*-8\.5 LUFS, -0\.5 dBTP/).to_stdout
      expect(MB::Sound.masters(:vinyl).notes).to match(/RIAA/)
    end
  end

  describe 'GraphNode#master' do
    it 'keeps the true peak under the ceiling' do
      out = run(test_mix(level: 0.6).master(:club), 48000, 800)
      a = MB::Sound::Loudness::Analyzer.new(channels: 2)
      a.process(out)
      expect(a.true_peak).to be <= -0.5 + 0.1
      expect(out.length).to eq(2)
    end

    it 'prints back in recipes' do
      g = test_mix.master(:streaming, platform: :apple)
      expect(g.to_ruby).to include('.master(:streaming, platform: :apple)')
    end
  end

  describe MB::Sound::GraphNode::Rider do
    it 'gives the same samples at any buffer size' do
      ref = run(test_mix.ride(-12, down: 0.5, up: 1), 96000, 800)
      expect(ref.map { |c| c.abs.max }).to all(be > 0.1)
      # (one-sample buffers for the first 0.4 s: the first gain decisions)
      { 1 => 19200, 7 => 40000, 128 => 96000, 4801 => 96000 }.each do |size, total|
        got = run(test_mix.ride(-12, down: 0.5, up: 1), total, size)
        expect(got.zip(ref).map { |a, b| (a - b[0...total]).abs.max }).to eq([0, 0]), "buffer size #{size}"
      end
    end

    it 'moves toward the target and stays within its range' do
      r = test_mix(level: 0.05).ride(-14, down: 0.3, up: 0.3, range: 20.db)
      run(r, 48000 * 6, 800)
      out = run(r, 48000 * 4, 800)
      a = MB::Sound::Loudness::Analyzer.new(channels: 2)
      a.process(out)
      expect(a.integrated).to be_within(0.5).of(-14)

      limited = test_mix(level: 0.05).ride(-6, up: 0.3, range: 3.db)
      run(limited, 48000 * 6, 800)
      expect(limited.gain).to be_within(0.01).of(3.0)
      expect(limited.gain).to be <= 3.0
    end

    it 'holds its gain through silence' do
      mix = MB::Sound::GraphNode::Channels.new([0.constant, 0.constant])
      r = mix.ride(-14, start: 4.db)
      run(r, 48000 * 4, 800)
      expect(r.gain).to eq(4.0)
      expect(r.linear_gain).to be_within(1e-12).of(4.db.to_f)
    end
  end

  describe 'Session#master with a preset' do
    it 'ends the chain with the preset and saves it in documents and undo' do
      s = session
      within(s) { MB::Sound.master(:club, lufs: -9) }
      expect(s.master_preset.call_ruby).to eq(':club, lufs: -9')
      s.process_buffer
      expect(s.master_info).to eq('master: :club, lufs: -9')

      text = MB::Sound::GraphIO.dump(s.arrangement, name: 'm')
      expect(text).to include("master :club, lufs: -9\n")
      b = session
      MB::Sound::GraphIO.load(text, session: b)
      expect(b.master_preset).to eq(s.master_preset)

      within(s) { MB::Sound.master { |mix| mix.softclip } }
      s.process_buffer
      within(s) { MB::Sound.undo(on: :now) }
      s.process_buffer
      expect(s.master_info).to eq('master: :club, lufs: -9')
    end

    it 'runs a block before the preset, and saves both' do
      s = session
      within(s) { MB::Sound.master(:quiet) { |mix| mix.filter(:highpass, cutoff: 30) } }
      text = MB::Sound::GraphIO.dump(s.arrangement, name: 'm')
      expect(text).to include("master(:quiet) { |mix|\n  mix.filter(:highpass, cutoff: 30)\n}")
      b = session
      MB::Sound::GraphIO.load(text, session: b)
      expect(b.master_preset.name).to eq(:quiet)
      expect(b.master_block).not_to be_nil
    end

    it 'takes an override (render master:, scripts\' --master)' do
      s = session
      s.mastering_override = :vinyl
      s.master(:club)
      expect(s.master_preset.name).to eq(:vinyl)
      s.master { |mix| mix.softclip }
      expect(s.master_preset.name).to eq(:vinyl)
      s.mastering_override = false
      s.master(:club)
      expect(s.master_preset).to be_nil
    end

    it 'shows the rider gain in master_info' do
      s = session
      s.add([110.hz.ramp.at(0.1), 110.hz.ramp.at(0.1)])
      s.master(:club, ride: true)
      60.times { s.process_buffer }
      expect(s.master_info).to match(/\Amaster: :club, ride: true \(ride \+\d+\.\d dB\)\z/)
    end

    it 'is a genre template master step' do
      t = MB::Sound.genre(:techno) {
        master nil
        master :club, lufs: -8, clip: false
      }
      expect(t.to_ruby).to include('master :club, lufs: -8, clip: false')
      s = session
      within(s) { t.setup }
      s.process_buffer
      expect(s.master_info).to start_with('master: ')
      chain = s.instance_variable_get(:@master_chains).last
      expect(chain.mastering.map(&:name)).to eq([:club])
      expect(chain.mastering[0].options).to eq(mono: 120, lufs: -8, clip: false)
    end

    it 'refuses options without a preset' do
      expect { MB::Sound.master(lufs: -8) }.to raise_error(ArgumentError, /go with a mastering preset/)
    end
  end

  describe 'render loudness targeting' do
    let(:song) {
      -> {
        MB::Sound.master :club
        c = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3).n8.loop
        MB::Sound.bg :keys, c.synth(voices: 4) { |v| v.hz.saw.rnd * v.env }.at(0.4)
        MB::Sound.bg :drums, MB::Sound.tr808(MB::Sound.grid(16, kick: 'x...x...x...x.x.', snare: '....x.......x...').loop)
      }
    }

    def render_song(path, **opts, &block)
      MB::Sound.seed(5)
      expect { MB::Sound.render(path, bars: 2, overwrite: true, **opts, &block) }.to output(/mastering :\w+: pass/).to_stdout
    end

    it 'reaches the target exactly, the same at any buffer size' do
      a = tmp_path('a.flac')
      render_song(a, &song)
      result = described_class::Targeting.last
      expect(result.integrated).to be_within(0.01).of(-8.5)
      la = MB::Sound.loudness(a)
      expect(la.integrated).to be_within(0.02).of(-8.5)
      expect(la.true_peak).to be <= -0.4

      b = tmp_path('b.flac')
      render_song(b, buffer_size: 128, &song)
      expect(described_class::Targeting.last.trim).to eq(result.trim)
      expect(MB::Sound.read(b)).to eq(MB::Sound.read(a))
    end

    it 'takes a loudness override, keeps stems, and renders once with loudness: false' do
      a = tmp_path('a.flac')
      render_song(a, loudness: -13, stems: tmp_path('stems_a'), &song)
      expect(MB::Sound.loudness(a).integrated).to be_within(0.02).of(-13)

      b = tmp_path('b.flac')
      MB::Sound.seed(5)
      expect { MB::Sound.render(b, bars: 2, loudness: false, stems: tmp_path('stems_b'), &song) }.not_to output(/mastering/).to_stdout
      expect(MB::Sound.loudness(b).integrated).not_to be_within(0.5).of(-13)
      expect(MB::Sound.read(File.join(tmp_path('stems_a'), 'keys.flac'))).to eq(MB::Sound.read(File.join(tmp_path('stems_b'), 'keys.flac')))
    end

    it 'masters through render(master:), holding a limiterless preset under its ceiling' do
      a = tmp_path('vinyl.flac')
      render_song(a, master: :vinyl, &song)
      r = MB::Sound.loudness(a)
      expect(r.true_peak).to be <= -1 + 0.05
      expect(described_class::Targeting.last.held).to eq(r.integrated < -14 - 0.05)
    end

    it 'stays exact with a block before the preset that reads a moving knob' do
      a = tmp_path('knob.flac')
      MB::Sound.seed(5)
      expect {
        MB::Sound.render(a, bars: 2, overwrite: true) {
          MB::Sound.knob :air, 20, range: 20..2000, curve: :exp
          MB::Sound.master(:club, lufs: -12) { |mix| mix.filter(:highpass, cutoff: MB::Sound.knob(:air)) }
          MB::Sound.bg :a, MB::Sound::GraphNode::Channels.new([110.hz.ramp.at(0.3), 82.5.hz.saw.at(0.3)])
          MB::Sound.at_bar(2) { MB::Sound.turn :air, 1500, over: 1 }
        }
      }.to output(/mastering :club: pass/).to_stdout
      expect(MB::Sound.loudness(a).integrated).to be_within(0.02).of(-12)
    end

    it 'masters a block that sets no master effects through render(master:)' do
      a = tmp_path('plain.flac')
      expect {
        MB::Sound.render(a, bars: 1, master: :quiet) { MB::Sound.bg :a, 220.hz.triangle.at(0.05).until(1.bar) }
      }.to output(/mastering :quiet: pass/).to_stdout
      expect(MB::Sound.loudness(a).integrated).to be_within(0.02).of(-18)
    end

    it 'measures a render window from its first frame' do
      a = tmp_path('window.flac')
      MB::Sound.seed(5)
      expect {
        MB::Sound.render(a, from: 2, bars: 1, overwrite: true) {
          MB::Sound.master :streaming
          # (a loud first bar that the file leaves out, then a quiet one)
          MB::Sound.bg :loud, 110.hz.ramp.at(0.5).until(1.bar)
          MB::Sound.at_bar(2) { MB::Sound.bg :quiet, 220.hz.triangle.at(0.03) }
        }
      }.to output(/mastering :streaming: pass/).to_stdout
      expect(MB::Sound.loudness(a).integrated).to be_within(0.02).of(-14)
    end

    it 'refuses a block that plays graphs built outside it' do
      g = 220.hz.ramp.at(0.2)
      expect {
        MB::Sound.render(tmp_path('x.flac'), bars: 1) { MB::Sound.master :quiet; MB::Sound.bg :a, g }
      }.to raise_error(ArgumentError, /built outside it/)
    end

    it 'refuses master: for prebuilt sounds unless loudness: false' do
      expect { MB::Sound.render(tmp_path('x.flac'), 220.hz.ramp, seconds: 0.1, master: :club) }.to raise_error(ArgumentError, /runs twice/)
      MB::Sound.render(tmp_path('y.flac'), 220.hz.ramp.at(0.1), seconds: 0.1, master: :club, loudness: false)
      expect(MB::Sound.read(tmp_path('y.flac'))[0].length).to eq(4800)
    end
  end

  describe '.codec_peaks' do
    it 'measures decoded true peaks of lossy encodes' do
      data = run(test_mix(level: 0.6).master(:club), 48000, 800)
      peaks = described_class.codec_peaks(data, codecs: %i[mp3 aac])
      expect(peaks.keys).to eq(%i[mp3 aac])
      expect(peaks.values).to all(be_between(-3, 3))
      expect { described_class.codec_peaks(data, codecs: [:wma]) }.to raise_error(ArgumentError, /Unknown codec :wma/)
    end
  end
end
