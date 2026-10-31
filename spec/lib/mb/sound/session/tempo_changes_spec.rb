RSpec.describe(MB::Sound::Session::TempoChanges) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) { new_session(transport) }

  after { session.close }

  def new_session(t, size = 800)
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: t,
      channels: 1, buffer_size: size, realtime: false, raise_errors: true
    )
  end

  # Renders +frames+ frames of +s+ in +size+-frame buffers; returns the
  # mix and [frame, position, bpm] at the start of every buffer.
  def run(s, frames, size = 800)
    out = []
    marks = []
    left = frames
    while left > 0
      n = [size, left].min
      marks << [s.frame, s.transport.position, s.transport.bpm]
      out << s.process_buffer(n)[0].dup
      left -= n
    end
    [SpecBuffers.join(out), marks]
  end

  def in_session(s = session, &block)
    MB::Sound::Session.with_context(session: s, &block)
  end

  # A clip voice whose output shows every note edge.
  def voice
    MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n16.loop.synth(voices: 2) { |v, _i| v.hz.asaw * v.gate * 0.2 }
  end

  describe MB::Sound::Sequence::TempoMap do
    let(:map) { described_class.constant(120) }

    it 'is static for one constant tempo' do
      expect(map).to be_static
      expect(map.bpm_at(17)).to eq(120)
      expect(map.next_break(0)).to be_nil
    end

    it 'ramps linearly in BPM over position, then holds the target' do
      m = map.ramp(140, at: 4, length: 4)
      expect(m.bpm_at(3)).to eq(120)
      expect(m.bpm_at(4)).to eq(120)
      expect(m.bpm_at(6)).to eq(130)
      expect(m.bpm_at(8)).to eq(140)
      expect(m.bpm_at(100)).to eq(140)
      expect(m.varying_at?(5)).to eq(true)
      expect(m.varying_at?(8)).to eq(false)
      expect(m.next_break(0)).to eq(4)
      expect(m.next_break(5)).to eq(8)
      expect(m.quiet_after?(9)).to eq(true)
      expect(m.quiet_after?(5)).to eq(false)
      expect(m.quiet_after?(2)).to eq(false) # (the ramp is ahead)
    end

    it 'keeps its history, but a step at the start or to the tempo in effect adds nothing' do
      m = map.ramp(140, at: 4, length: 4).step(100, at: 12)
      expect(m.segments.length).to eq(3)
      expect(m.bpm_at(6)).to eq(130) # (seeks read it)
      expect(m.step(100, at: 16)).to eq(m)
      expect(m.step(90, at: 0)).to be_static
      # a ramp cut short ends where the next segment starts
      cut = map.ramp(140, at: 4, length: 4).step(90, at: 6)
      expect(cut.bpm_at(7)).to eq(90)
      expect(cut.next_break(5)).to eq(6)
      expect(cut.next_break(6)).to be_nil
    end

    it 'round-trips its rows (for a take start state)' do
      m = map.ramp(140, at: 4, length: 4, curve: MB::Sound::Curve[:smooth]).step(100, at: 12)
      rows = m.rows
      expect(rows.first).to eq([nil, 120])
      expect(described_class.from_rows(rows)).to eq(m)
      expect(MB::Sound::RubyValue.to_ruby(rows)).to match(/Curve\[:smooth/)
    end

    it 'shapes ramps with a curve and quantizes inside them' do
      m = map.ramp(180, at: 0, length: 1, curve: MB::Sound::Curve[:smooth])
      v = m.bpm_at(1/4r)
      expect(v).to be < 135 # a smoothstep starts slower than a line
      expect((v * 1024).denominator).to eq(1)
    end

    it 'builds step maps from [position, bpm] pairs (a MIDI file tempo map)' do
      m = described_class.steps([[8, 90], [0, 120]])
      expect(m.bpm_at(-1)).to eq(120)
      expect(m.bpm_at(8)).to eq(90)
      expect(m.next_break(0)).to eq(8)
      expect(m.quiet_after?(100)).to eq(true)
    end

    it 'solves a ramp length in whole notes from seconds' do
      # constant tempo: 4 s at 120 BPM is 2 whole notes
      expect(described_class.ramp_length_for_seconds(120, 120, 4)).to eq(2)
      # 120 -> 240 linear: time per whole note is 240 * ln(2) / 120 s
      len = described_class.ramp_length_for_seconds(120, 240, 10)
      expect(len.to_f).to be_within(1e-6).of(10 * 120 / (240 * Math.log(2)))
    end

    it 'prints its segments' do
      expect(map.ramp(140, at: 4, length: 2).to_s).to include('ramp(4r, 120r => 140r, length: 2r)') # (exact Rationals, printers-1)
    end
  end

  describe 'ramps' do
    it 'lands on the exact frame and moves the tempo in 800-frame cells to the target' do
      session.add(voice, name: :x)
      in_session { MB::Sound.bpm(180, over: 1, at: MB::Sound.bar(2)) }
      _, marks = run(session, 96000 * 3)

      # bar 1 at 120
      expect(marks.select { |f, _, _| f < 96000 }.map(&:last).uniq).to eq([120])
      # the ramp reads the tempo in cells, then holds 180
      ramp = marks.select { |f, pos, _| f >= 96000 && pos < 2 }
      expect(ramp.map(&:last).each_cons(2).all? { |a, b| b >= a }).to eq(true)
      expect(marks.last.last).to eq(180)
      expect(transport.tempo_moves?).to eq(false) # back on the constant path after the ramp
      expect(session.journal.entries.map(&:kind)).to include(:tempo)
    end

    it 'renders the same frames at the same tempos at any buffer size' do
      results = [[800], *slow_tier([[367], [64]])].map do |(size)|
        t = MB::Sound::Sequence::Transport.new(bpm: 120)
        s = new_session(t, size)
        s.add(voice, name: :x)
        in_session(s) { MB::Sound.bpm(150, over: 1.bars, curve: :smooth, at: MB::Sound.bar(1, beat: 3)) }
        data, marks = run(s, 96000 * 2 + 4800, size)
        s.close
        [data, marks.to_h { |f, pos, bpm| [f, [pos, bpm]] }, t.position]
      end
      ref = results.first
      expect(ref[0].abs.max).to be > 0.1
      results.drop(1).each do |data, marks, pos|
        expect((data - ref[0]).abs.max).to eq(0)
        expect(pos).to eq(ref[2])
        (marks.keys & ref[1].keys).each { |f| expect(marks[f]).to eq(ref[1][f]) }
      end
    end

    it 'ramps from where a ramp in progress is when a new tempo lands' do
      session.add(voice, name: :x)
      in_session { MB::Sound.bpm(200, over: 2) }
      run(session, 96000)
      mid = transport.bpm
      expect(mid).to be > 130
      in_session { MB::Sound.bpm(100, over: 1) }
      seg = transport.tempo_map.segments.last
      expect(seg).to be_a(MB::Sound::Sequence::TempoMap::Ramp)
      expect(seg.from).to be_within(1).of(mid.to_r) # (the ramp's own tempo where the new one lands)
      run(session, 96000 * 2)
      expect(transport.bpm).to eq(100)
    end

    it 'ends with a plain bpm (one constant tempo, as before)' do
      in_session { MB::Sound.bpm(200, over: 2) }
      expect(transport.tempo_moves?).to eq(true)
      MB::Sound::Session.with_context(session: session) { MB::Sound.bpm(90) }
      expect(transport.tempo_moves?).to eq(false)
      expect(transport.bpm).to eq(90)
    end

    it 'undoes a ramp' do
      session.add(voice, name: :x)
      run(session, 800)
      in_session { MB::Sound.bpm(180, over: 1) }
      run(session, 9600)
      expect(transport.bpm).to be > 120
      session.undo(on: :now)
      run(session, 800)
      expect(transport.bpm).to eq(120)
      expect(transport.tempo_moves?).to eq(false)
    end

    it 'reads the map at a seek target: inside a ramp, the ramp plays on from there (tempo-2)' do
      session.add(voice, name: :x)
      in_session { MB::Sound.bpm(180, over: 2) }
      run(session, 96000 * 3) # (past the ramp's end: 180 holds)
      expect(transport.bpm).to eq(180)
      expect(transport.tempo_moves?).to eq(false)

      # into the ramp (bar 2: halfway): what the ramp reaches there
      in_session { MB::Sound.seek(2) }
      expect(transport.bpm).to eq(150)
      _, marks = run(session, 96000)
      bpms = marks.map(&:last)
      expect(bpms.each_cons(2).all? { |a, b| b >= a }).to eq(true) # (it ramps on to 180)
      expect(bpms[1]).to be > 150
      expect(bpms.last).to eq(180)

      # undo puts the timeline back where the seek landed (past the
      # ramp), and the tempo with it
      before = session.journal.entries.find { |e| e.kind == :seek }.lands.pos
      expect(before).to be > 2
      session.undo(on: :now)
      expect(transport.position).to eq(before)
      expect(transport.bpm).to eq(180)
    end

    it 'plays the tempo before a later change after a seek back, and the change again where it was' do
      session.add(voice, name: :x)
      run(session, 96000)
      in_session { MB::Sound.bpm(150) } # (at bar 2)
      run(session, 96000)
      in_session { MB::Sound.seek(1) }
      expect(transport.bpm).to eq(120)
      _, marks = run(session, 96000 + 9600)
      change = marks.find { |_, _, bpm| bpm == 150 }
      expect(change[1]).to eq(1) # (bar 2 again, at its buffer's start: 96000 frames at 120)
    end

    it 'reads a map assigned whole (from a MIDI file) at the new position, and steps on its breakpoints' do
      session.add(voice, name: :x)
      transport.tempo_map = MB::Sound::Sequence::TempoMap.steps([[0, 100], [2, 150]])
      in_session { MB::Sound.seek(3.5) } # (bar 3.5: position 2.5)
      run(session, 800)
      expect(transport.bpm).to eq(150)
      in_session { MB::Sound.seek(1) }
      run(session, 800)
      expect(transport.bpm).to eq(100)
      _, marks = run(session, 96000 * 3)
      change = marks.each_cons(2).find { |a, b| a[2] != b[2] }
      expect(change[1][1]).to be >= 2
      expect(marks.find { |_, pos, _| pos > 2 }[2]).to eq(150)
    end

    it 'takes seconds as the ramp length' do
      in_session { MB::Sound.bpm(240, over: 4.seconds) }
      seg = transport.tempo_map.segments.last
      expect(seg.length.to_f).to be_within(1e-5).of(4 * 120 / (240 * Math.log(2)))
    end

    it 'explains ranges and shapes without a ramp' do
      expect { in_session { MB::Sound.bpm(90..180) } }.to raise_error(ArgumentError, /ramp.*knob.*LFO/)
      expect { in_session { MB::Sound.bpm(140, curve: :smooth) } }.to raise_error(ArgumentError, /over:/)
      expect { in_session { MB::Sound.bpm(140, over: -1) } }.to raise_error(ArgumentError, /over:/)
    end

    it 'has accel and rit spellings' do
      in_session { MB::Sound.accel(160, over: 2) }
      expect(transport.tempo_map.segments.last.to).to eq(160)
      in_session { MB::Sound.rit(80, over: 2) }
      expect(transport.tempo_map.segments.last.to).to eq(80)
    end
  end

  describe 'plain bpm (tempo-2: journaled)' do
    it 'is a journaled, undoable :tempo change' do
      e = in_session { MB::Sound.bpm(140) }
      expect(e).to be_a(MB::Sound::Session::Journal::Entry)
      expect([e.kind, e.status]).to eq([:tempo, :landed])
      expect(transport.bpm).to eq(140)
      expect(transport.tempo_moves?).to eq(false)
      expect(in_session { MB::Sound.bpm }).to eq(140)
      session.undo(on: :now)
      expect(transport.bpm).to eq(120)
    end

    it 'lands on its exact frame from a scheduled block, the same at any buffer size' do
      results = [800, *slow_tier([367], keep: 0)].map do |size|
        t = MB::Sound::Sequence::Transport.new(bpm: 120)
        s = new_session(t, size)
        s.add(voice, name: :x)
        read = nil
        in_session(s) {
          MB::Sound.at_bar(2, beat: 2) {
            MB::Sound.bpm(150)
            read = [MB::Sound.bpm, 1.bars.to_seconds.to_f] # (the rest of the block reads the queued tempo)
          }
        }
        data, = run(s, 96000 * 3, size)
        e = s.journal.entries.find { |x| x.kind == :tempo && x.status == :landed }
        s.close
        [data, e.lands.frame, read]
      end
      data, frame, read = results.first
      expect(frame).to eq(96000 + 24000) # (bar 2, beat 2 at 120 BPM: on its frame, not its buffer's start)
      expect(read[0]).to eq(150)
      expect(read[1]).to be_within(1e-9).of(1.6)
      results.drop(1).each do |d, f, _|
        expect(f).to eq(frame)
        expect((d - data).abs.max).to eq(0)
      end
    end

    it 'refuses a range with what it might have meant (maintainer, 2026-10-30: "Error")' do
      expect { in_session { MB::Sound.bpm(90..180) } }.to raise_error(ArgumentError) { |e|
        expect(e.message.lines.length).to eq(1)
        expect(e.message).to include('did you mean', 'bpm 90; bpm 180, over: 4.bars', 'knob :tempo, 90, range: 90..180; bpm :tempo', 'bpm 4.bars.lfo.at(90..180)')
      }
      expect { in_session { MB::Sound.tempo(90..180, over: 8.bars) } }.to raise_error(ArgumentError, /bpm 180, over: 8.bars/)
      expect { in_session { MB::Sound.bpm(90.bpm..180.bpm) } }.to raise_error(ArgumentError, /bpm 90; bpm 180/)
      expect { in_session { MB::Sound.bpm(-3) } }.to raise_error(ArgumentError, /positive/)
      expect(session.journal.entries).to be_empty
    end
  end

  describe 'followed tempo' do
    it 'follows a knob read once per cell, the same at any buffer size' do
      results = [800, *slow_tier([367])].map do |size|
        t = MB::Sound::Sequence::Transport.new(bpm: 120)
        s = new_session(t, size)
        s.add(voice, name: :x)
        in_session(s) do
          MB::Sound.knob(:tempo, 120, range: 60..200)
          MB::Sound.bpm(:tempo)
          MB::Sound.turn(:tempo, 180, over: 1)
        end
        data, = run(s, 96000 * 2, size)
        r = [data, t.position, t.bpm]
        s.close
        r
      end
      expect(results.first[2]).to be_within(0.01).of(180)
      results.drop(1).each do |data, pos, _|
        expect((data - results.first[0]).abs.max).to eq(0)
        expect(pos).to eq(results.first[1])
      end
    end

    it 'follows tempo LFOs and Tempo-ranged knobs' do
      session.add(voice, name: :x)
      in_session { MB::Sound.bpm(1.bars.lfo.at(100..140)) }
      _, marks = run(session, 96000 * 2)
      bpms = marks.map { |m| m[2].to_f }
      expect(bpms.min).to be < 105
      expect(bpms.max).to be > 135

      in_session do
        MB::Sound.knob(:t, (90.bpm..180.bpm).at(140.bpm))
        MB::Sound.bpm(MB::Sound.knob(:t))
      end
      run(session, 1600)
      expect(transport.bpm).to eq(140)
    end

    it 'points audio-rate sources at a knob that follows them' do
      expect { in_session { MB::Sound.bpm(0.1.hz.lfo.at(90..180)) } }.to raise_error(ArgumentError, /turn :tempo, follow: node; bpm :tempo/)
    end
  end

  describe 'Tempo ranges' do
    it 'compares tempos' do
      expect(0.5.bpm..2.bpm).to cover(1.bpm)
      expect(90.bpm < 180.bpm).to eq(true)
      expect(90.bpm <=> 90).to be_nil
    end
  end

  describe 'scenes and sections' do
    it 'ramps the tempo from a scene value' do
      in_session do
        MB::Sound.track(:x, voice)
        MB::Sound.scene(:a, x: :on)
        MB::Sound.scene(:b, x: :on, bpm: [160, over: 1])
        MB::Sound.go(:a, at: :now)
      end
      run(session, 800)
      in_session { MB::Sound.go(:b) } # next bar
      run(session, 96000 * 3)
      expect(transport.bpm).to eq(160)
      expect(session.journal.entries.select { |e| e.kind == :tempo && e.status == :landed }.map { |e| e.lands.pos }).to eq([1r])
    end

    it 'places a ramp from the pass start when a seek enters the pass mid-way, as an uninterrupted run plays it (tempo-2)' do
      [:section, :scene].each do |where|
        t = MB::Sound::Sequence::Transport.new(bpm: 120)
        s = new_session(t)
        in_session(s) do
          MB::Sound.track(:x, voice)
          MB::Sound.scene(:a, x: :on)
          where == :scene ? MB::Sound.scene(:b, x: :on, bpm: [160, over: 2]) : MB::Sound.scene(:b, x: :on)
          ramp = where == :section ? { bpm: [160, over: 2] } : {}
          MB::Sound.flow(seed: 1, on: :now) do
            a 2
            b 4, **ramp
          end
        end
        run(s, 96000)
        in_session(s) { MB::Sound.seek(4) } # (bar 4: halfway through b's 2-bar ramp from bar 3)
        expect(t.bpm).to eq(140), "#{where}: the ramp's tempo at bar 4"
        seg = t.tempo_map.segments.last
        expect([seg.pos, seg.from, seg.to]).to eq([2, 120, 160])
        run(s, 48000)
        here = t.position
        expect(here).to be < 4 # (still in the ramp)
        # a seek back to a, and its undo: back in b's ramp where it was
        in_session(s) { MB::Sound.seek(1) }
        expect(t.bpm).to eq(120)
        run(s, 800)
        s.undo(on: :now)
        expect(t.position).to eq(here)
        expect(t.bpm).to eq(t.tempo_map.bpm_at(here))
        expect(t.bpm).to be > 140
        seg = t.tempo_map.segments.last
        expect([seg.pos, seg.from, seg.to]).to eq([2, 120, 160]), "#{where}: the undo relaunches b with its ramp from bar 3"
        run(s, 96000 * 2)
        expect(t.bpm).to eq(160)
        s.close
      end
    end

    it 'refuses bad scene tempo values' do
      in_session { MB::Sound.track(:x, voice) }
      expect { in_session { MB::Sound.scene(:c, x: :on, bpm: [160, oops: 1]) } }.to raise_error(ArgumentError, /bpm: takes a tempo/)
    end
  end

  describe 'takes' do
    # Plays console +lines+ ({ buffer index => [code, ...] }) for +count+
    # 800-frame buffers into a take, then checks that the saved take
    # replays the live mix bit for bit at 800 and 367/368-frame buffers.
    def expect_take_replays(lines, count)
      b = MB::Sound::Take.console_binding
      MB::Sound.seed(3)
      t = MB::Sound::Take.new(session: session)
      out = []
      count.times do |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
        out << session.process_buffer[0].dup
      end
      live = SpecBuffers.join(out)
      expect(live.abs.max).to be > 0.1

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved the take/).to_stdout
      load path
      r = MB::Sound::Take::Replay.last
      [[800], *slow_tier([[367, 368]], keep: 1)].each do |sizes|
        MB::Sound.seed(3)
        data = []
        r.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| data << mix[0].dup }
        data = SpecBuffers.join(data)
        n = [data.length, live.length].min
        first = (0...n).find { |i| data[i] != live[i] }
        expect(first).to be_nil, "first difference at frame #{first} at buffer sizes #{sizes}"
        expect(data.length).to be >= live.length
        diff = (data[0...live.length] - live).abs.max
        expect(diff).to eq(0), "max difference #{diff} at buffer sizes #{sizes}"
      end
      t
    end

    it 'replays a ramp with a scene change and a seek inside it at any buffer size', render_budget: { seconds: 70, reason: 'a 6-bar performance and replays at two buffer sizes' } do
      lines = {
        0 => [
          "track(:x, q: 1) { |c| c.number * c.gate * 0.002 }", # (no tones: their phases differ by ~1e-12 between buffer sizes, see Take::Replay)
          'track :pad, 0.05.constant', # (clipless, started by :two after the seek's target: omnibus16)
          'a = seq(C4, E4, G4).n16.loop',
          'scene :one, x: a',
          'scene :two, x: a.transpose(5), pad: :on, bpm: [150, over: 2]',
          'go :one, at: :now',
        ],
        37 => ['bpm 90, over: 3'],
        150 => ['go :two'],
        260 => ['seek 2'],
        330 => ['knob :tempo, 120, range: 60..200', 'bpm :tempo', 'turn :tempo, 170, over: 1'],
      }
      t = expect_take_replays(lines, 560)
      expect(t.entries.map(&:kind)).to include(:tempo, :seek, :scene)
    end

    it 'replays a ramp the take started in, plain tempos, and seeks back into the ramp (tempo-2)', render_budget: { seconds: 60, reason: 'a 4-bar performance and replays at two buffer sizes' } do
      in_session { MB::Sound.bpm(160, over: 3) } # (before the take: its start state)
      lines = {
        0 => [
          "track(:x, q: 1) { |c| c.number * c.gate * 0.002 }",
          'scene :one, x: seq(C4, E4, G4).n16.loop',
          'go :one, at: :now',
        ],
        90 => ['bpm 100'], # (cuts the ramp short)
        140 => ['seek 2, 3'], # (back into the ramp)
        200 => ['bpm 130', 'seek 1'], # (a step, then back before it)
        300 => ['undo'],
      }
      t = expect_take_replays(lines, 400)
      expect(t.start[:tempo_map]).to eq([[nil, 120], [0, 120, 160, 3]])
      expect(t.entries.select { |e| e.kind == :tempo }.length).to eq(2)
    end
  end
end
