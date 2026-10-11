RSpec.describe(MB::Sound::Take) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 0.5, output: null_output, transport: transport, channels: 2, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:take) { MB::Sound::Take.new(session: session) }

  after { session.close }

  # The performance: console lines typed after the given number of
  # 800-frame buffers (a few land mid-bar, as typing does).
  def performance(tones:)
    voice = tones ? 'c.tone.ramp.lp4(900, resonance: 0.3) * c.amp_env * 0.3' : 'c.number * 0.01'
    pad = tones ? '220.hz.triangle * 0.1' : '0.1.constant'
    {
      0 => [
        'a = seq(C3, E3, G3, B3).n8.loop',
        'b = seq(A2, C3, E3, G3).n8.loop',
        "track(:bass, q: 1) { |c| #{voice} }",
        "track :pad, #{pad}",
        'scene :intro, pad: :on',
        'scene :verse, pad: :on, bass: a',
        'scene :turn, pad: :on, bass: b',
        'go :intro, at: :now',
      ],
      97 => ['go :verse'],
      250 => ['mute :pad'],
      300 => ['unmute :pad, at: :bar'],
      371 => ['bg :spark, 0.05.constant, fade: 1/4r'],
      450 => ['go :turn', 'swap :bass, a, on: 4'], # two queued changes for one track
      470 => ['undo'],                                # cancels the swap (not landed yet)
      530 => ['solo :bass, fade: 1/8r'],
      600 => ['solo'],
      650 => ['stop :spark, fade: 1/2r'],
      700 => ['undo at: :now'],
      760 => ['mutes :breakdown, :pad, :spark', 'mute :breakdown, at: :bar, fade: 1'],
    }
  end

  # Plays the performance live (lines evaluated between buffers, like the
  # console), returning the mix (left channel) and the take.
  def perform(tones:, buffers: 960)
    lines = performance(tones: tones)
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    buffers.times do |i|
      lines.fetch(i, []).each do |code|
        MB::Sound::Session.with_context(session: session) { t.line(code, b) }
      end
      out << session.process_buffer[0].dup
    end
    [out.reduce(:concatenate), t]
  end

  def replay(replay, sizes)
    out = []
    replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
    out.reduce(:concatenate)
  end

  it 'records lines with their issue times and where their changes landed' do
    data, t = perform(tones: false, buffers: 120)
    expect(data.abs.max).to be > 0
    go = t.lines.find { |l| l.code == 'go :verse' }
    expect(go.issued.frame).to eq(97 * 800)
    expect(go.lands).to eq([1r, 1r]) # the scene and the bass track, on bar 2
    expect(t.entries.map(&:kind)).to include(:scene, :bg)
    expect(t.inspect).to include('go :verse')
  end

  it 'replays bit for bit at the same and at other buffer sizes' do
    live, t = perform(tones: false)
    expect(live.abs.max).to be > 0.1

    path = tmp_path('take.rb')
    expect { t.save(path) }.to output(/Saved the take to/).to_stdout
    load path
    r = MB::Sound::Take::Replay.last
    expect(r.lines.length).to eq(t.lines.length)

    [[800], [367, 368], [64], [1001, 13]].each do |sizes|
      MB::Sound.seed(5)
      data = replay(r, sizes)
      expect(data.length).to be >= live.length
      diff = (data[0...live.length] - live).abs.max
      expect(diff).to eq(0), "max difference #{diff} at buffer sizes #{sizes}"
    end
  end

  it 'replays tones exactly at the same buffer size and within 1e-6 at others' do
    live, t = perform(tones: true)
    r = t.replay

    MB::Sound.seed(5)
    d = (replay(r, [800])[0...live.length] - live).abs
    expect(d.max).to eq(0)

    MB::Sound.seed(5)
    expect((replay(r, [367, 368])[0...live.length] - live).abs.max).to be < 1e-6
  end

  it 'replays a song form performance (labels, weighted goto, pick, loop!, a re-decided commit, goto a label, seek, skip, undo, a meter change) bit for bit' do
    lines = {
      0 => [
        'k = grid(16, kick: "x...x...x...x...").fill(snare: grid(16, "....x.x.xxxxxxxx", value: 38)).loop',
        'a = seq(C3, E3, G3, B3).n8.loop',
        'b = seq(A2, C3, E3, G3).n8.loop',
        'track(:bass) { |c| c.notes.number * 0.01 }',
        'track(:drums) { |c| c[:kick].notes.velocity * 0.5 + c[:snare].notes.velocity * 0.25 }',
        'scene :intro, drums: k',
        'scene :verse, drums: k, bass: a',
        'scene :chorus, drums: k, bass: b',
        'scene :bridge, drums: k, bass: b.transpose(5)',
        'scene :roll, bass: a.transpose(12), others: :keep',
        'flow(seed: 9) { fill :small, every: 2; intro 2; label :v; verse 2, fill: :roll; goto c: 1, v: 1; label :c; chorus 2; pick { |p| p.option(1) { }; p.option(1) { bridge 1 } }; goto :v }',
      ],
      290 => ['loop!'],         # verse pass 1, before its commit point (bar 4)
      650 => ['onward'],        # after the second pass's commit point: the next boundary
      # Inside the scheduler's half-bar lookahead before the third verse
      # pass's commit point (bar 8): the commit block already ran live,
      # so this re-decides it (replays run the line first)
      820 => ['goto :chorus'],
      1000 => ['meter 3, 4'],   # from bar 10
      1100 => ['goto :c'],      # a label: the chorus next
      1180 => ['seek :v, on: :bar'], # the timeline back to the verse's last start (bar 3)
      1290 => ['undo'],         # back to bar 12 (a seek too) at the next bar line
      1420 => ['skip in: 1.beat, on: :beat'], # (not an undo step)
    }
    run = lambda {
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: session)
      out = []
      1500.times do |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
        out << session.process_buffer[0].dup
      end
      [out.reduce(:concatenate), t]
    }
    live, t = run.call
    expect(live.abs.max).to be > 0.1
    history = session.arrangement.playback.history
    # loop! (verse x3), goto :chorus, goto :c (the label: chorus again),
    # seek :v (the verse from bar 3), undo (back into the chorus at bar
    # 12, not a new pass), the pick's bridge, skip
    expect(history).to eq([:intro, :verse, :verse, :verse, :chorus, :chorus, :verse, :bridge])
    timeline = session.journal.changes.select { |e| [:seek, :skip, :restore].include?(e.kind) }.map(&:to_s)
    expect(timeline).to eq(['seek :v landed 12:1', 'restore :timeline landed 4:1', 'skip :form landed 13:1'])
    expect(t.to_ruby).to include("ends_epoch: 2,\n", ", epoch: 1\n")
    expect(session.transport.meters.length).to eq(2)

    r = t.replay
    [[800], [367, 368]].each do |sizes|
      MB::Sound.seed(5)
      data = replay(r, sizes)
      diff = (data[0...live.length] - live).abs.max
      expect(diff).to eq(0), "max difference #{diff} at buffer sizes #{sizes}"
    end
  end

  it 'keeps foreground commands out of replays' do
    t = MB::Sound::Take.new(session: session)
    b = MB::Sound::Take.console_binding
    MB::Sound::Session.with_context(session: session) do
      t.line('x = 1', b)
      t.line('players', b)
      t.line('take', b) rescue nil
    end
    expect(t.lines.map(&:skipped)).to eq([false, true, true])
    expect(t.to_ruby).to include('# skipped (foreground): players')
  end

  it 'saves to the user data directory by default, or a set home' do
    allow(described_class).to receive(:data_dir).and_return(tmp_path('takes'))
    path = nil
    expect { path = take.save }.to output(/Saved the take to .*takes\/take_\d+_\d+\.rb/).to_stdout
    expect(File.executable?(path)).to eq(true)

    take.home = tmp_path('sets')
    expect { path = take.save }.to output(/sets\/take_/).to_stdout
  end

  it 'gives the user data directory per platform' do
    expect(described_class.data_dir).to end_with('mb-sound/takes')
  end
end
