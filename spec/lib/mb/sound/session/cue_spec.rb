RSpec.describe(MB::Sound::Session::Cue, :aggregate_failures) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  CUE_SPEC_BAR = 96000

  # A NullOutput that keeps what is written (every channel).
  class CueCapture < MB::Sound::NullOutput
    attr_reader :written

    def write(data)
      (@written ||= []) << data.map(&:dup)
      super
    end

    # The channels written so far, joined.
    def channels_written
      @written.transpose.map { |c| SpecBuffers.join(c) }
    end
  end

  def new_session(output_channels: 4, cue_output: nil)
    out = CueCapture.new(channels: output_channels, sleep: false)
    MB::Sound::Session.new(
      master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2,
      buffer_size: 800, realtime: false, raise_errors: true, cue_output: cue_output
    ).tap { |s| (@sessions ||= []) << s }
  end

  after { @sessions&.each(&:close) }

  # Renders +frames+ frames in buffers of +sizes+ (cycled), calling the
  # block with the session frame before each buffer.  Returns every output
  # channel written.
  def run(s, frames, sizes = [800])
    left = frames
    sizes = sizes.cycle
    while left > 0
      yield s.frame if block_given?
      n = [sizes.next, left].min
      MB::Sound::Session.with_context(session: s) { s.process_buffer(n) }
      left -= n
    end
    s.output.channels_written
  end

  def player(s, name)
    s.instance_variable_get(:@players).values.find { |p| p.name == name && p.current? }
  end

  it 'plays a cue player on CUE (channels 3-4) only, dry, leaving MAIN untouched' do
    s = new_session
    s.master { |mix| mix * 0.5 }
    s.add(0.25.constant, name: :a)
    s.cue_player(:b, 0.125.constant, start_time: 0)
    main_l, main_r, cue_l, cue_r = run(s, 1600)
    expect(main_l.to_a.uniq).to eq([0.125]) # :a through the master chain; :b adds exactly nothing
    expect(main_r.to_a.uniq).to eq([0.125])
    expect(cue_l.to_a.uniq).to eq([0.125]) # :b dry (no master chain)
    expect(cue_r.to_a.uniq).to eq([0.125])
    expect(s.players.keys).to include(:a, :"b/cue")
    expect(s.cue_info.keys).to eq([:b])
    expect(s.cue_info[:b]).to start_with('cue: Constant')
    expect(s.knobs.keys).to include(:phones, :cue_mix)
  end

  it 'launches a cue to MAIN on the exact frame, the same player and graph carrying on' do
    s = new_session
    s.add(0.5.constant, name: :b)
    s.cue_player(:b, 0.1.hz.saw.at(0.5), start_time: 0) # rising from 0 for 5 s: a restart would show
    run(s, 800)
    p0 = player(s, :"b/cue")
    s.launch_cue(:b, time: 1r)
    main, _, cue, _ = run(s, 2 * CUE_SPEC_BAR)
    declick = (MB::Sound::Session::Fades::DECLICK_SECONDS * 48000).round

    expect(main[0...CUE_SPEC_BAR].to_a.uniq).to eq([0.5]) # old :b until the bar
    expect(cue[CUE_SPEC_BAR - 1]).to be > 0
    p1 = player(s, :b)
    expect(p1).to equal(p0)
    expect(player(s, :"b/cue")).to be_nil
    # After the crossfade, MAIN is the ramp continuing, CUE silent
    expect(main[CUE_SPEC_BAR + declick + 10]).to be_within(1e-4).of(cue[CUE_SPEC_BAR - 1] + (declick + 11) * 0.1 / 48000)
    expect(cue[(CUE_SPEC_BAR + declick)..].abs.max).to eq(0)
    expect((main[CUE_SPEC_BAR + declick + 1] - main[CUE_SPEC_BAR + declick]).abs).to be < 1e-4 # continuous, no restart
    expect(s.journal.entries.map(&:kind)).to include(:launch)
  end

  it 'renders CUE and MAIN the same at any buffer size' do
    results = [[800], [128], [7, 801, 33]].map { |sizes|
      s = new_session
      s.add(220.hz.sine.at(0.25), name: :a)
      s.cue_player(:b, 330.hz.saw.at(0.25), start_time: 1/4r)
      s.knob(:cue_mix, 0.0, range: 0.0..1.0)
      s.knob(:phones, 1.0, range: 0.0..2.0)
      s.launch_cue(:b, time: 1r, fade: 1/4r)
      s.pfl(:a, time: 5/4r)
      s.turn(:cue_mix, 0.5, over: 1/2r, start_time: 3/2r)
      run(s, 2 * CUE_SPEC_BAR, sizes)
    }
    expect(results[0][2].abs.max).to be > 0.2
    results.drop(1).each do |r|
      r.zip(results[0]).each { |a, b| expect((a - b).abs.max).to eq(0) }
    end
  end

  it 'pre-listens a playing player and ends it with uncue' do
    s = new_session
    s.add(0.5.constant, name: :a)
    run(s, 800)
    s.pfl(:a)
    expect(s.pfl?(:a)).to eq(true)
    run(s, 1600)
    s.uncue
    expect(s.pfl?(:a)).to eq(false)
    main, _, cue, _ = run(s, 1600)
    expect(main.to_a.uniq).to eq([0.5])
    expect(cue[0...800].to_a.uniq).to eq([0])
    expect(cue[1600..2399].to_a.uniq).to eq([0.5])
    expect(cue[-800..].to_a.uniq).to eq([0])
  end

  it 'undoes and redoes a launch without restarting either graph' do
    s = new_session
    s.add(0.5.constant, name: :b)
    s.cue_player(:b, 0.25.constant, start_time: 0)
    run(s, 800)
    old = player(s, :b)
    cued = player(s, :"b/cue")
    s.command('launch :b') { s.launch_cue(:b) }
    run(s, 4800)
    expect(player(s, :b)).to equal(cued)
    s.undo(on: :now)
    main, _, cue, _ = run(s, 4800)
    expect(player(s, :"b/cue")).to equal(cued)
    expect(player(s, :b).input).to equal(old.input)
    expect(main[-800..].to_a.uniq).to eq([0.5])
    expect(cue[-800..].to_a.uniq).to eq([0.25])
    s.redo(on: :now)
    main, _, cue, _ = run(s, 4800)
    expect(player(s, :b)).to equal(cued)
    expect(main[-800..].to_a.uniq).to eq([0.25])
    expect(cue[-800..].to_a.uniq).to eq([0])
  end

  it 'keeps cue players playing through solos, and mutes them with their name' do
    s = new_session
    s.add(0.5.constant, name: :a)
    s.cue_player(:b, 0.25.constant, start_time: 0)
    s.solo(:a)
    _, _, cue, _ = run(s, 1600)
    expect(cue[-800..].to_a.uniq).to eq([0.25])
    s.mute(:b)
    _, _, cue, _ = run(s, 1600)
    expect(cue[-800..].to_a.uniq).to eq([0])
  end

  it 'blends MAIN into the phones with :cue_mix and scales them with :phones' do
    s = new_session
    s.add(0.5.constant, name: :a)
    s.cue_player(:b, 0.25.constant, start_time: 0)
    s.turn(:cue_mix, 0.5, smooth: 0)
    s.turn(:phones, 2, smooth: 0)
    _, _, cue, _ = run(s, 1600)
    expect(cue[-1]).to be_within(1e-6).of((0.25 * 0.5 + 0.5 * 0.5) * 2)
  end

  describe 'on 2-channel outputs' do
    it 'splits from the exact frame of the first cue by default, MAIN stereo before it, at any buffer size' do
      outs = [[800], [128], [7, 801]].map { |sizes|
        s = new_session(output_channels: 2)
        expect(s.cue_mode).to eq(:off)
        s.add(MB::Sound.stereo(0.5.constant, 0.25.constant), name: :a)
        s.cue_player(:b, 0.125.constant, start_time: 1/8r) # frame 12000
        out = run(s, 24000, sizes)
        expect(s.cue_mode).to eq(:split)
        out
      }
      l, r = outs[0]
      expect(l[0...12000].to_a.uniq).to eq([0.5])
      expect(r[0...12000].to_a.uniq).to eq([0.25])
      expect(l[12000..].to_a.uniq).to eq([0.375])
      expect(r[12000..].to_a.uniq).to eq([0.125])
      outs.drop(1).each { |o| o.zip(outs[0]).each { |a, b| expect(a).to eq(b) } }
    end

    it 'warns once per user, in the console, the first time CUE splits a 2-channel output' do
      ENV['MB_SOUND_HELP_DIR'] = tmp_path('help')
      MB::Sound.live = true
      s = new_session(output_channels: 2)
      expect { s.cue_player(:b, 0.1.constant) }.to output(/CUE on 2 channels.*cue_output :phones.*cue_output :off/m).to_stderr
      expect(MB::Sound::Session::Cue::Prefs.split_warned?).to eq(true)
      s2 = new_session(output_channels: 2)
      expect { s2.cue_player(:c, 0.1.constant) }.not_to output.to_stderr
    ensure
      MB::Sound.live = false
      ENV.delete('MB_SOUND_HELP_DIR')
    end

    it 'keeps MAIN in stereo with cue_output :off' do
      s = new_session(output_channels: 2, cue_output: :off)
      s.add(MB::Sound.stereo(0.5.constant, 0.25.constant), name: :a)
      s.cue_player(:b, 0.125.constant, start_time: 0)
      expect(run(s, 800).map { |c| c.to_a.uniq }).to eq([[0.5], [0.25]])
    end

    it 'splits MAIN (left) and the phones (right) in mono with :split' do
      s = new_session(output_channels: 2, cue_output: :split)
      s.add(MB::Sound.stereo(0.5.constant, 0.25.constant), name: :a)
      s.cue_player(:b, 0.125.constant, start_time: 0)
      expect(run(s, 800).map { |c| c.to_a.uniq }).to eq([[0.375], [0.125]])
    end

    it 'plays the phones mix on both channels with :phones' do
      s = new_session(output_channels: 2, cue_output: :phones)
      s.add(0.5.constant, name: :a)
      s.cue_player(:b, 0.125.constant, start_time: 0)
      expect(run(s, 800).map { |c| c.to_a.uniq }).to eq([[0.125], [0.125]])
    end

    it 'refuses :ports' do
      s = new_session(output_channels: 2)
      expect { s.cue_output = :ports }.to raise_error(ArgumentError, /4-channel output/)
    end
  end

  it 'renders ignore CUE' do
    s = new_session
    s.add(0.5.constant, name: :a)
    s.cue_player(:b, 0.25.constant, start_time: 0)
    mix = MB::Sound::Session.with_context(session: s) { s.process_buffer(800) }
    expect(mix.length).to eq(2)
    expect(mix[0].to_a.uniq).to eq([0.5])
  end

  describe 'console' do
    around do |ex|
      s = new_session
      MB::Sound::Session.with_context(session: s) { ex.run }
    end

    let(:s) { MB::Sound::Session.current }

    it 'cues a track on a clip and launches it at the track quantization, adopting the clip' do
      a = MB::Sound.seq(MB::Sound::C3).n4.loop
      b = MB::Sound.seq(MB::Sound::G3).n4.loop
      MB::Sound.track(:t, q: 1) { |c| c.gate * c.number * 0.001 }
      MB::Sound.bg :t, a
      run(s, 800)
      e = MB::Sound.cue :t, b
      expect(e.kind).to eq(:bg)
      expect(e.subject).to eq(:"t/cue")
      run(s, 800)
      e = MB::Sound.launch :t
      expect(e.kind).to eq(:launch)
      expect(e.lands.pos).to eq(1r)
      expect(s.arrangement.tracks[:t].clip).to equal(b)
      main, _, cue, _ = run(s, CUE_SPEC_BAR)
      expect(main[CUE_SPEC_BAR - 2000]).to be_within(1e-6).of(MB::Sound::C3.number * 0.001)
      expect(cue[CUE_SPEC_BAR - 2000]).to be_within(1e-6).of(MB::Sound::G3.number * 0.001)
      main, _, cue, _ = run(s, 4800)
      expect(main[-1]).to be_within(1e-6).of(MB::Sound::G3.number * 0.001)
      expect(cue[-1]).to eq(0)
    end

    it 'keeps launch :track, ref for clip slots, and raises for nothing cued' do
      expect { MB::Sound.launch :nothing }.to raise_error(ArgumentError, /Nothing cued/)
      expect(MB::Sound.method(:launch).super_method.owner).to eq(MB::Sound::ArrangementMethods)
    end

    it 'ends a cue player when bg replaces its name, at the same time' do
      MB::Sound.bg :a, 0.5.constant
      MB::Sound.cue :a, 0.25.constant
      run(s, 800)
      MB::Sound.bg :a, 0.125.constant, on: :beat
      expect(s.cued?(:a)).to eq(true)
      main, _, cue, _ = run(s, 30000)
      expect(s.cued?(:a)).to eq(false)
      expect(cue[-800..].to_a.uniq).to eq([0])
      expect(main[-800..].to_a.uniq).to eq([0.125])
      expect(cue[23000 - 800]).to eq(0.25) # still cued just before the beat (frame 24000)
    end

    it 'cues a scene and launches it with the cued graphs taking over' do
      a = MB::Sound.seq(MB::Sound::C3).n4.loop
      b = MB::Sound.seq(MB::Sound::G3).n4.loop
      MB::Sound.track(:t, q: 1) { |c| c.gate * c.number * 0.001 }
      MB::Sound.track(:u, q: 1) { |c| c.gate * c.number * 0.0001 }
      MB::Sound.scene :one, t: a, u: a
      MB::Sound.scene :two, t: b, u: a
      MB::Sound.go :one, at: :now
      run(s, 800)
      MB::Sound.cue :two
      expect(MB::Sound.cues.keys).to eq([:t])
      cued = player(s, :"t/cue")
      u = player(s, :u)
      e = MB::Sound.launch :two
      expect(e.kind).to eq(:scene)
      main, _, cue, _ = run(s, CUE_SPEC_BAR + 4800)
      expect(player(s, :t)).to equal(cued)
      expect(player(s, :u)).to equal(u)
      expect(s.arrangement.tracks[:t].clip).to equal(b)
      expect(main[-1]).to be_within(1e-6).of(MB::Sound::G3.number * 0.001 + MB::Sound::C3.number * 0.0001)
      expect(cue[-1]).to eq(0)
    end

    it 'sets the phones blend with cue_mix and saves it as the starting blend' do
      ENV['MB_SOUND_HELP_DIR'] = tmp_path('help')
      expect(MB::Sound.cue_mix).to eq(0)
      MB::Sound.cue_mix 0.25, save: true, smooth: 0
      run(s, 800)
      expect(MB::Sound.cue_mix).to eq(0.25)
      expect(MB::Sound::Session::Cue::Prefs.cue_mix).to eq(0.25)
      expect(MB::Sound::Session.cue_mix_default).to eq(0.25)
      s2 = new_session
      expect(s2.cue_knobs[1].value).to eq(0.25)
    ensure
      MB::Sound::Session.cue_mix_default = 0
      ENV.delete('MB_SOUND_HELP_DIR')
    end

    it 'pre-listens with cue :name and lists cues' do
      MB::Sound.bg :a, 0.5.constant
      run(s, 800)
      e = MB::Sound.cue :a
      expect(e.kind).to eq(:cue)
      expect(MB::Sound.cues).to eq(a: 'pfl')
      MB::Sound.uncue :a
      expect(MB::Sound.cues).to eq({})
      expect(MB::Sound.cue_output).to eq(:auto)
    end
  end

  it 'replays cue, launch, pre-listen, and undo from a take bit for bit at any buffer size, CUE included' do
    s = new_session
    lines = {
      0 => ['bg :a, 220.hz.triangle.at(0.2)', 'cue :b, 330.hz.saw.at(0.2)'],
      30 => ['a2 = seq(A2, C3).n8.loop', 'b2 = seq(E3, G3).n8.loop', 'track(:k, q: 1) { |c| c.number * 0.002 * c.gate }', 'scene :s1, k: a2', 'scene :s2, k: b2', 'go :s1'],
      50 => ['launch :b, fade: 1.beat', 'cue :s2'],
      130 => ['launch :s2'],
      170 => ['cue :a', 'turn :cue_mix, 0.3, over: 1'],
      260 => ['undo'],
      300 => ['uncue'],
    }
    bnd = MB::Sound::Take.console_binding
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: s)
    360.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { t.line(code, bnd) } }
      MB::Sound::Session.with_context(session: s) { s.process_buffer }
    end
    live = s.output.channels_written
    expect(live[2].abs.max).to be > 0.1
    expect(t.entries.map(&:kind)).to include(:launch, :cue, :restore)

    r = t.replay
    [[800], [129, 7, 800]].each do |sizes|
      MB::Sound.seed(5)
      out = CueCapture.new(channels: 4, sleep: false)
      r.render(out, buffer_sizes: sizes, tail: 0) { |_| }
      got = out.channels_written
      4.times do |c|
        diff = (got[c][0...live[c].length] - live[c]).abs.max
        expect(diff).to be <= (sizes == [800] ? 0 : 1e-4), "channel #{c}: max difference #{diff} at buffer sizes #{sizes}"
      end
    end
  end
end
