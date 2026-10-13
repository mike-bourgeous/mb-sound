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

  it 'replays played MIDI, controller moves, learn, monitors, and recorded and captured clips bit for bit' do
    ev = MB::Sound::MIDI::Event
    played = [[60, 2.1r, 2.35r], [64, 2.6r, 2.9r], [67, 3.3r, 4.5r], [72, 3.99r, 4.2r], [48, 4.25r, 4.5r], [55, 5r, 5.8r]]
    events = played.flat_map { |n, on, off| [ev.parse([0x90, n, 90], time: on), ev.parse([0x80, n, 64], time: off)] }
    events += (0..20).map { |i| ev.parse([0xb0, 74, 6 * i], time: 1 + Rational(i, 40)) } # a sweep after learn
    session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))

    lines = {
      0 => [
        'track(:lead, q: 1) { |c| c.number * c.gate * 0.01 }',
        'track(:bass, q: 1) { |c| c.number * c.gate * 0.001 }',
        'knob :cut, 0.5, takeover: :jump, smooth: 0',
        'bg :k, knob(:cut) * 0.1, on: :now',
      ],
      10 => ['arm :lead', 'rec 1'],
      30 => ['learn :cut'],
      250 => ['capture :bass, 1, quantize: 16'],
    }
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    480.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    live = out.reduce(:concatenate)
    expect(live.abs.max).to be > 0.3
    expect(session.arrangement.captures.keys).to eq([:lead_1, :bass_1])
    expect(session.knobs[:cut].cc).to eq(74)
    expect(session.journal.changes.map(&:kind)).to include(:learn, :rec, :capture, :cc)
    expect(t.midi[nil].length).to eq(events.length)
    expect(t.to_s).to include("#{events.length} MIDI events")

    path = tmp_path('midi_take.rb')
    expect { t.save(path) }.to output(/Saved the take/).to_stdout
    expect(File.read(path)).to include('r.midi [', '[0, 21/20r, [144, 60, 90]],')
    load path
    saved = MB::Sound::Take::Replay.last

    [[t.replay, [800]], [saved, [800]], [saved, [367, 368]], [saved, [64]]].each do |r, sizes|
      MB::Sound.seed(5)
      data = replay(r, sizes)
      diff = (data[0...live.length] - live).abs.max
      expect(diff).to eq(0), "max difference #{diff} at buffer sizes #{sizes}"
    end
  end

  it 'replays knob turns, ramps, snapshots, crossfades, and undo bit for bit' do
    lines = {
      0 => [
        'knob :g, 0.5, range: 0.01..1, curve: :exp',
        'knob :lvl, 0.2',
        'a = seq(C3, E3, G3, B3).n8.loop',
        'track(:bass, q: 1) { |c| c.number * 0.01 * knob(:g) }',
        'track :pad, knob(:lvl) * 1',
        'scene :one, pad: :on, bass: a, g: 0.25',
        'scene :two, pad: :on, bass: a, g: [1, over: 1/2r], lvl: 0.4',
        'go :one, at: :now',
        'snap :start',
      ],
      97 => ['turn :g, 0.05, over: 1.beat, curve: :smooth'],
      151 => ['move :lvl, 0.6, in: 1.beat'],
      240 => ['go :two'],
      333 => ['snap :wide', 'recall :start, over: 1/2r'],
      400 => ['undo'],
      470 => ['knob :morph, 0', 'xfade :start, :wide, :morph', 'turn :morph, 1, over: 1, on: :bar'],
      620 => ['turn :lvl, 0.9, at: bar(8, beat: 2)'],
    }
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    720.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    live = out.reduce(:concatenate)
    expect(live.abs.max).to be > 0.1
    expect(t.entries.map(&:kind)).to include(:turn, :snap, :restore)

    r = t.replay
    [[800], [367, 368], [64]].each do |sizes|
      MB::Sound.seed(5)
      data = replay(r, sizes)
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

  # Plays +lines+ (a Hash from buffer index to console lines) live for
  # +buffers+ buffers of +size+ frames.  Returns the mix (left channel)
  # and the take.
  def perform_lines(lines, buffers:, size: 800, seed: 5)
    bnd = MB::Sound::Take.console_binding
    MB::Sound.seed(seed)
    t = MB::Sound::Take.new(session: session)
    out = []
    buffers.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
      out << session.process_buffer(size)[0].dup
    end
    [out.reduce(:concatenate), t]
  end

  [
    ['a tempo set by the first line', 'cut: 3500', nil],
    ['a scene knob ramp', 'cut: [3500, from: 350, over: 1]', nil],
    ['section knob values', 'cut: 16000', 'b 2, cut: [3500, over: 1.beat]'],
    ['a track with lead: launched by the first section', 'cut: 3500', nil, 'lead: 1.beat'],
    ['a track with lead: 0.3.attack', 'cut: 3500', nil, 'lead: 0.3.attack'],
  ].each do |label, b_knob, b_section, lead|
    it "replays #{label} bit for bit at the same buffer size and within 1e-4 at others" do
      lines = {
        0 => [
          'bpm 165',
          'knob :cut, 16000, range: 200..16000, curve: :exp',
          "track(:t#{lead ? ", #{lead}" : ''}) { |c| c.synth(voices: 10) { |v| v.hz.unison(3, detune: 0.12) { |p, _i| p.saw } * v.env(0.6, 0.5, 0.8, 1.2, gm: false) * 0.25 }.filter(:lowpass, cutoff: knob(:cut), quality: 0.9) * 0.3 }",
          # (align: :launch: a lead launched now counts the clip from
          # before the first sample)
          'scene :a, t: seq(A2.n2.d, E3.n4).loop(align: :launch), cut: 16000',
          "scene :b, t: seq(A2, C3).n8.loop, #{b_knob}",
          "flow { a 1; #{b_section || 'b 2'} }",
        ],
      }
      live, t = perform_lines(lines, buffers: 200)
      expect(live.abs.max).to be > 0.02

      # Through the saved script (a lead's launch saves [landing, time])
      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      expect(File.read(path)).to match(/r\.line 0r, \[.*\[0r, -\d+\/\d+r\]/) if lead
      load path
      r = MB::Sound::Take::Replay.last
      [[800], [367, 368]].each do |sizes|
        MB::Sound.seed(5)
        data = replay(r, sizes)
        expect(data.length).to be >= live.length
        diff = (data[0...live.length] - live).abs.max
        # (Tones accumulate their phase per buffer; see Take::Replay)
        expect(diff).to be <= (sizes == [800] ? 0 : 1e-4), "max difference #{diff} at buffer sizes #{sizes}"
      end
    end
  end

  it 'replays a take that ends (players ring out) to where its timeline stops, at any buffer size' do
    # Live in 1000-frame buffers: the timeline stops at the end of the
    # buffer in which the last player ends (bar 2 + 1000 frames), which a
    # replay in other buffer sizes may never reach
    _live, t = perform_lines({ 0 => ['bg :x, 0.1.constant.until(1.bar)'] }, buffers: 120, size: 1000)
    expect(t.replay.ends).to eq(97000r / 96000)
    expect(t.to_ruby).to include("seconds: 2.5,\n")

    [[800], [367, 368], [1000]].each do |sizes|
      frames = 0
      expect {
        frames = t.replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| }
      }.not_to output.to_stderr
      expect(frames).to be_between(96000, 98000)
    end
  end

  it 'warns when a replay goes quiet with take lines left to run' do
    r = MB::Sound::Take::Replay.new(bpm: 120, bar_length: 1r, master_gain: 0.5, fade_in: nil, fade_out: nil, rng: nil, ends: 6r) { |rp|
      rp.line(0r, [0r], 'bg :x, 0.1.constant.until(1.bar)')
      rp.line(5r, [5r], 'bg :y, 0.1.constant')
    }
    frames = 0
    expect {
      frames = r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0)
    }.to output(/went quiet at 2:1.*1 take line left to run.*ends at 7:1/).to_stderr
    expect(frames).to be_between(96000, 97600)
  end

  it 'stops a replay that never reaches its end after its length plus EXTRA_SECONDS, or MAX_SECONDS' do
    stub_const('MB::Sound::Take::Replay::EXTRA_SECONDS', 0.5)
    stub_const('MB::Sound::Take::Replay::MAX_SECONDS', 0.25)
    make = ->(seconds) {
      MB::Sound::Take::Replay.new(bpm: 120, bar_length: 1r, master_gain: 0.5, fade_in: nil, fade_out: nil, rng: nil, ends: 1000r, seconds: seconds) { |rp|
        # A seek back to the start every half bar: the timeline never gets
        # past bar 1
        rp.line(0r, [0r], 'bg :x, 0.1.constant; every(1/2r) { seek 1 }')
      }
    }

    count = 0
    expect {
      expect(make.(1).render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0) { |_| count += 1 }).to eq(72000)
    }.to output(/Stopped replaying the take after 1.5 seconds without reaching its end.*pass max_seconds:/).to_stderr
    expect(count).to eq(90)

    expect {
      expect(make.(nil).render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0)).to eq(12000)
    }.to output(/after 0.25 seconds/).to_stderr

    expect {
      expect(make.(nil).render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0, max_seconds: 0.5)).to eq(24000)
    }.to output(/after 0.5 seconds/).to_stderr
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
