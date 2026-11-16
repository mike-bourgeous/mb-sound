require_relative '../../../../support/ui_helpers'

RSpec.describe(MB::Sound::UI::Perf) do
  let(:perf_class) { MB::Sound::UI::Perf }

  # A fake clock the examples move by hand
  let(:clock) { Struct.new(:t) { def call = t }.new(100.0) }

  def frame(f, at:, late: 0.0, paint: 0.001, write: 0.0005, skipped: 0)
    MB::Sound::UI::Pacer::Frame.new(at: at, paint: paint, write: write, sleep: 0.01, slept: 0.01, late: late, skipped: skipped, wrote: 0)
  end

  describe 'records' do
    it 'keeps each frame, the worst gap between written frames, and pane update ages' do
      p = perf_class.new(clock: clock, ack: nil)
      t = 100.0
      10.times do |i|
        t += i == 6 ? 0.2 : 1 / 60.0
        p.begin_frame(t)
        p.pane_drew(:scope, t, i.zero? ? nil : t - (i == 6 ? 0.2 : 1 / 60.0))
        p.painted(1, false, i.zero?, 500)
        p.wrote(t + 0.001, t + 0.002)
        p.end_frame(frame(p, at: t, late: i == 6 ? 0.18 : 0.0))
      end
      clock.t = t
      s = p.summary
      expect(s[:frames]).to eq(10)
      expect(s[:full_redraws]).to eq(1)
      expect(s[:late_ms][:max]).to eq(180.0)
      expect(s[:worst_written_gap][:ms]).to be_within(0.1).of(200.0)
      expect(s[:panes][:scope][:max]).to be_within(0.01).of(200.0)
      expect(s[:panes][:scope][:stale]).to eq(1)
      expect(s[:stalest_pane][:name]).to eq(:scope)
      expect(p.headline[0]).to match(/worst stall: 200\.\d ms/)
    end

    it 'times a key to the first frame written after its handler ran (REPL keys: a frame that redrew the REPL)' do
      p = perf_class.new(clock: clock, ack: nil)
      p.key(100.0, 100.001, false) # a NAV key
      p.key(100.0, 100.001, true)  # a REPL key: its echo comes through the pty
      p.begin_frame(100.010)
      p.painted(1, false, false, 100)
      p.wrote(100.011, 100.012)
      p.begin_frame(100.030)
      p.painted(1, true, false, 100)
      p.wrote(100.031, 100.032)
      s = p.summary
      expect(s[:keys][:n]).to eq(2)
      expect(s[:keys][:min]).to eq(12.0)
      expect(s[:keys][:max]).to eq(32.0)
      expect(s[:keys][:no_change]).to eq(0)
    end

    it 'counts a key no frame showed within KEY_TIMEOUT as no change' do
      p = perf_class.new(clock: clock, ack: nil)
      p.key(100.0, 100.001, true)
      p.begin_frame(101.5)
      p.painted(1, false, false, 100)
      p.wrote(101.5, 101.6)
      expect(p.summary[:keys]).to include(n: 0, no_change: 1)
    end

    it 'sends a query after a sampled frame and takes its answer out of the input, counting lost ones' do
      p = perf_class.new(clock: clock, ack: :da1, ack_every: 0.25)
      expect(p.ack_query(100.0)).to eq("\e[c")
      expect(p.ack_query(100.01)).to be_nil # (one at a time)
      p.wrote(100.0, 100.002)
      reply = MB::Term::Input::Reply.new(kind: :device, data: [62, 22])
      expect(p.reply(reply, 100.007)).to eq(true)
      expect(p.reply(reply, 100.008)).to eq(false) # (not ours: none was asked)
      expect(p.ack_query(100.1)).to be_nil # (not due yet)
      expect(p.ack_query(100.3)).to eq("\e[c")
      p.wrote(100.3, 100.3)
      expect(p.ack_query(103.0)).to eq("\e[c") # (the last one lost after ACK_TIMEOUT: counted, and the next one goes)
      s = p.summary[:acks]
      expect(s).to include(queries: 3, answered: 1, lost: 1)
      expect(s[:from_write_end_ms][:p50]).to eq(5.0)
      expect(s[:from_write_start_ms][:p50]).to eq(7.0)
    end

    it 'records XTVERSION and DA2 answers as the identity, asked with the next written frame' do
      p = perf_class.new(clock: clock, ack: :da1)
      term = Object.new
      p.identify(features: { device: [62, 22], sync: true }, term: term, size: [40, 120])
      expect(p.expect_dcs?(100.0)).to eq(true)
      expect(p.ack_query(100.0)).to eq("\e[>0q\e[>c")
      expect(p.reply(MB::Term::Input::Reply.new(kind: :dcs, data: '>|Konsole 24.08.3'), 100.01)).to eq(true)
      expect(p.reply(MB::Term::Input::Reply.new(kind: :device2, data: [1, 240_802, 0]), 100.01)).to eq(true)
      expect(p.identity).to include(xtversion: 'Konsole 24.08.3', da2: [1, 240_802, 0], da1: [62, 22], size: [40, 120])
      expect(p.expect_dcs?(100.02)).to eq(false)
    end

    it 'allocates nothing per frame while recording' do
      p = perf_class.new(clock: clock, ack: nil)
      f = frame(p, at: 100.0)
      run = ->(n) {
        n.times do |i|
          t = 100.0 + i / 60.0
          p.begin_frame(t)
          p.pane_drew(:scope, t, t - 0.016)
          p.painted(2, true, false, 400)
          p.wrote(t, t + 0.001)
          p.end_frame(f)
        end
      }
      run.(10)
      before = GC.stat(:total_allocated_objects)
      run.(1000)
      expect(GC.stat(:total_allocated_objects) - before).to be < 20
    end
  end

  describe 'report and save' do
    it 'prints a page with frames, panes, keys, the terminal, and writes report.txt, summary.json, frames.json' do
      p = perf_class.new(clock: clock, ack: :da1)
      p.begin_frame(100.0)
      p.pane_drew(:meters, 100.0, 99.98)
      p.painted(1, false, true, 2000)
      p.wrote(100.0, 100.001)
      p.end_frame(frame(p, at: 100.0))
      clock.t = 101.0
      text = MB::U.remove_ansi(p.report.to_s)
      expect(text).to include('UI frame instruments', 'Frames', 'Panes', 'meters', 'Keys and the terminal', 'Terminal')
      dir = p.save(tmp_path('cap'))
      expect(File.read(File.join(dir, 'report.txt'))).to include('worst stall')
      json = JSON.parse(File.read(File.join(dir, 'summary.json')))
      expect(json).to include('frames' => 1, 'machine' => a_hash_including('cores'))
      frames = JSON.parse(File.read(File.join(dir, 'frames.json')))
      expect(frames['bytes']).to eq([2000])
      expect(frames['panes']['meters'].length).to eq(1)
    end
  end

  describe "on the tiled screen" do
    after { @tiles&.stop; @term&.close }

    it 'records real frames, keys typed in the REPL, and terminal answers that never reach Pry or NAV' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      @term.wait_for('t> ')
      p = @tiles.start_perf(ack_every: 0.05)
      wait_until { p.summary[:acks][:answered] >= 3 }
      @term.type('12')
      wait_until { p.summary[:keys][:n] >= 2 }
      @tiles.stop_perf
      s = p.summary
      expect(s[:frames]).to be > 5
      expect(s[:acks][:lost]).to eq(0)
      expect(s[:panes]).not_to be_empty
      expect(s[:keys][:p95]).to be < 1000
      # The answers never reached Reline (no "62;22c" typed) nor the status line
      expect(@term.text).not_to include('62;22c')
      expect(@tiles.host.vt.text).not_to include('62')
      expect(@tiles.perf).to be_nil
    end
  end
end
