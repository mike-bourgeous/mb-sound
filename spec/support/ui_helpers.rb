# Fake snapshots for terminal UI specs (spec/lib/mb/sound/ui/): a set in
# its drop, with tracks, a queued change, knobs, master levels, and a scope,
# all fixed (no Session), so band text is deterministic.
module UIHelpers
  UI = MB::Sound::UI

  def ui_knob_spec(name, default, range, **opts)
    MB::Sound::GraphNode::Knob::Spec.new(name: name, default: default, range: range, **opts)
  end

  # The Slow part: tracks, scenes, queued changes, a recording, the form.
  def ui_fake_slow
    UI::Slow.new(
      tracks: [
        UI::TrackInfo.new(name: :drums, q: '1', clip: 'beat_a', armed: false),
        UI::TrackInfo.new(name: :bass, q: '1', clip: 'bass_a', armed: false),
        UI::TrackInfo.new(name: :lead, q: '1', clip: 'no clip', armed: true),
        UI::TrackInfo.new(name: :pad, q: '1', clip: 'chords', armed: false),
      ].freeze,
      scenes: %i[intro drop break].freeze,
      scene: :drop,
      queued: [
        UI::QueuedInfo.new(seq: 9, kind: :mute, subject: :pad, lands: '18:1', pos: 17r),
        UI::QueuedInfo.new(seq: 8, kind: :knob, subject: :cut, lands: '17:3', pos: 16.5r),
      ].freeze,
      recording: [UI::RecordingInfo.new(name: :lead, ends: '21:1', pos: 20r, queued: false)].freeze,
      armed: [:lead].freeze,
      form: UI::FormInfo.new(section: :drop, pass: 1, from: 12r, to: 20r, next: :break, next_at: '21:1', committed: true, looping: false, ended: false),
      knob_specs: {}.freeze
    )
  end

  # A full Snapshot at bar 17 beat 3 (+t+ seconds, +seq+), with a 440 Hz
  # scope of +scope_phase+.
  def ui_fake_snapshot(t: 1.0, seq: 1, scope_phase: 0.0, peak: -8.1)
    scope = [0.7, 0.35].map { |a|
      Numo::SFloat.new(1024).seq.map { |i| a * Math.sin(2 * Math::PI * (440.0 * i / 48000 + scope_phase)) }.freeze
    }.freeze
    UI::Snapshot.fake(
      seq: seq, time: t, frame: 1_536_000, pos: 16.5r, bar: 17, beat: 3r, bpm: 128, bar_length: 1r, playing: true,
      load: 0.31, load_max: 0.45,
      parts: [
        UI::PartLoad.new(name: :drums, kind: :player, state: :playing, load: 0.04),
        UI::PartLoad.new(name: :bass, kind: :player, state: :playing, load: 0.12),
        UI::PartLoad.new(name: :pad, kind: :player, state: :stopping, load: 0.02),
        UI::PartLoad.new(name: :verb, kind: :bus, state: :playing, load: 0.06),
        UI::PartLoad.new(name: :master, kind: :master, state: :playing, load: 0.03),
      ].freeze,
      master: UI::MasterLevels.new(peak: [peak, peak - 0.3].freeze, rms: [-18.0, -18.2].freeze, true_peak: -0.6, lufs_s: -14.2),
      scope: scope,
      underruns: 0,
      knobs: [
        UI::KnobValue.new(name: :cut, value: 2400.0, spec: ui_knob_spec(:cut, 800.0, 100.0..8000.0, curve: :exp, unit: 'Hz')),
        UI::KnobValue.new(name: :drive, value: 0.3, spec: ui_knob_spec(:drive, 0.0, 0.0..1.0)),
      ].freeze,
      slow: ui_fake_slow
    )
  end

  # A Band on a StringIO, +size+ [rows, cols], painting only on #refresh,
  # drawing ui_fake_snapshot (or the block's snapshot for each refresh).
  def ui_fake_band(layout = :band, size: [30, 120], native: true, at: :top, color: :ansi256, &snap)
    io = StringIO.new
    snap ||= -> { ui_fake_snapshot }
    band = UI::Band.new(layout: UI.layout_named(layout), io: io, size: size, native: native, at: at, color: color, clock: -> { 0.0 }, source: snap)
    [band, io]
  end

  # A terminal for headless :tiles specs: a pty pair whose slave is the
  # "real" terminal the screen owns, and a UI::VT reading the master (what
  # the screen wrote), answering its queries.
  class FakeTerminal
    attr_reader :vt, :master, :slave

    def initialize(rows, cols)
      require 'pty'
      @master, @slave = PTY.open
      @slave.winsize = [rows, cols]
      @vt = MB::Sound::UI::VT.new(rows, cols, scrollback: 0)
      @lock = Mutex.new
      @bytes = 0
      @reader = Thread.new do
        loop do
          d = @master.readpartial(65_536)
          @lock.synchronize do
            @bytes += d.bytesize
            @vt.feed(d)
            r = @vt.take_replies
            @master.write(r) unless r.empty?
          end
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    # Bytes the screen wrote so far.
    def bytes = @lock.synchronize { @bytes }

    # Types +str+ a character at a time (as a person would).
    def type(str, delay: 0.002)
      str.each_char do |c|
        @master.write(c)
        sleep delay
      end
    end

    # Writes +str+ at once (an escape sequence, a paste).
    def write(str) = @master.write(str)

    def text = @lock.synchronize { @vt.text }
    def lines = @lock.synchronize { @vt.lines }

    # Waits until the screen shows +what+ (a String or Regexp).
    def wait_for(what, timeout: 8)
      deadline = MB::U.clock_now + timeout
      until MB::U.clock_now > deadline
        t = text
        return true if what.is_a?(Regexp) ? t.match?(what) : t.include?(what)
        sleep 0.02
      end
      false
    end

    # Waits until the screen stops changing for +quiet+ seconds.
    def settle(quiet: 0.25, timeout: 5)
      deadline = MB::U.clock_now + timeout
      last = bytes
      t = MB::U.clock_now
      until MB::U.clock_now > deadline
        sleep 0.02
        b = bytes
        if b != last
          last = b
          t = MB::U.clock_now
        elsif MB::U.clock_now - t >= quiet
          return true
        end
      end
      false
    end

    def resize(rows, cols)
      @lock.synchronize { @vt.resize(rows, cols) }
      @slave.winsize = [rows, cols]
      Process.kill(:WINCH, Process.pid)
    end

    def close
      @master.close rescue nil
      @slave.close rescue nil
      @reader.join(1)
    end
  end

  # A keyboard output that plays nothing (UI.keyboard's Link would start
  # the default Session, realtime, whose shared transport then keeps
  # moving under later examples).
  class NullKeyboardOut
    def note_on(*, **) = nil
    def note_off(*, **) = nil
    def cc(*, **) = nil
  end

  # Waits up to +timeout+ seconds for the block to be truthy; returns its
  # last value.
  def wait_until(timeout: 5)
    deadline = MB::U.clock_now + timeout
    sleep 0.01 until yield || MB::U.clock_now > deadline
    yield
  end

  # A Tiles screen on a FakeTerminal with a Pry of its own (prompt "t> "),
  # started with threads, its keyboard playing into NullKeyboardOut unless
  # +keyboard:+ is given.  Returns [tiles, terminal].
  def ui_tiles(layout = :tiles, rows: 30, cols: 100, **opts)
    require 'pry'
    opts[:keyboard] ||= MB::Sound::UI::Keyboard.new(out: NullKeyboardOut.new)
    term = FakeTerminal.new(rows, cols)
    prompt = Pry::Prompt.new('ui-spec', 'ui spec', [proc { 't> ' }, proc { 't* ' }])
    tiles = UI::Tiles.new(layout: UI.tiles_layout_named(layout), input: term.slave, output: term.slave, repl: :thread,
                          pry: { prompt: prompt, color: false, correct_indent: false }, probe: false, **opts)
    tiles.start
    [tiles, term]
  end
end

RSpec.configure do |c|
  c.include UIHelpers
end
