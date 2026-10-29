# Fake snapshots for terminal UI specs (spec/lib/mb/sound/ui/): a set in
# its drop, with tracks, a queued change, knobs, master levels, and a scope,
# all fixed (no Session), so band text is deterministic.
module UIHelpers
  UI = MB::Sound::UI

  # The RENDER pane renders on the drawing thread in UI specs (no worker
  # threads from panes drawn by every capture), with renders timed at 0 ms
  # so captures are the same every run; PatchRender's own specs use Workers
  # and the real clock where they test them.
  UI::PatchRender.inline = true
  UI::PatchRender.clock = -> { 0.0 }

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
      knob_specs: {}.freeze,
      matrix: ui_fake_matrix,
      racks: ui_fake_racks,
      inspector: ui_fake_inspector,
      render_source: ui_fake_render_source,
      buses: [UI::BusInfo.new(name: :verb, to: :master, description: 'reverb(:hall)', asleep: false, muted: false, sends: %i[pad].freeze, sources: [].freeze),
              UI::BusInfo.new(name: :drums, to: :master, description: 'compress', asleep: false, muted: false, sends: [].freeze, sources: %i[drums].freeze)].freeze,
      routes: { pad: { to: :master, send: { verb: 0.25 } }, drums: { to: :drums, send: {} } }.freeze
    )
  end

  # The inspector's data for a bass track reading knob +knob+ (sound
  # design screen): an lp4 driven by it, a highpass with a real preview,
  # a shaper, and the graph's Ruby; +prefix+ goes on names (text fitting).
  def ui_fake_inspector(prefix = '', knob: :cut)
    tr = MB::Sound::GraphNode::Traversable
    pv = ->(value, unit: nil, label: nil, detail: nil, range: nil) { tr::ParamValue.new(value: value, type: :control, unit: unit, range: range, label: label, detail: detail) }
    hp = { structure: :svf, filter_type: :highpass, sample_rate: 48000.0, cutoff: 150.0, quality: 0.7, gain: nil, db_gain: nil, label: 'highpass 150.0 Hz Q 0.7' }
    params = ->(cls, values, preview = nil) { Ractor.make_shareable(tr::Params.new(node_class: cls, name: nil, values: values, preview: preview)) }
    # (in sections, as UI::Inspect::Classify sorts a real reese: copies
    # per voice and channel, stereo after the unison)
    nodes = [
      UI::Inspect::NodeInfo.new(key: 0, label: "#{prefix}lp4", role: 'filter', count: 1, knobs: [knob].freeze,
                                params: params.(MB::Sound::GraphNode::FourPole, { cutoff: pv.(2400.0, unit: 'Hz', label: knob), resonance: pv.(0.25, detail: 'literal') }), preview: false,
                                section: :filter, channels: 2),
      UI::Inspect::NodeInfo.new(key: 1, label: "#{prefix}highpass", role: 'filter', count: 2, knobs: [].freeze,
                                params: params.(MB::Sound::Filter::SampleWrapper, { cutoff: pv.(150, unit: 'Hz'), quality: pv.(0.7, unit: ' Q') }, hp), preview: true,
                                section: :fx, what: 'post-amp EQ', channels: 2),
      UI::Inspect::NodeInfo.new(key: 2, label: 'softclip', role: 'shaper', count: 1, knobs: [].freeze,
                                params: params.(MB::Sound::GraphNode::Shaper, {}, { mode: :softclip, p1: 0.35, p2: 0.95, label: 'softclip' }), preview: true,
                                section: :amp, what: 'drive', channels: 2),
      UI::Inspect::NodeInfo.new(key: 3, label: 'saw', role: 'osc', count: 6, knobs: [].freeze,
                                params: params.(MB::Sound::Notes::KeyedTone, { frequency: pv.(nil, detail: "#{prefix}notes frequency"), phase: pv.(0) }), preview: false,
                                section: :source),
    ].freeze
    code = "synth(#{prefix}riff, voices: 1) { |v|\n  saws = v.hz.unison(6, detune: 0.32) { |p, _i| p.saw }\n  saws.lp4(knob(#{knob.inspect}), resonance: 0.25).softclip(0.35, 0.95).filter(:highpass, cutoff: 150, quality: 0.7)\n}"
    UI::Inspect::InspectInfo.new(track: :"#{prefix}bass", tracks: [:drums, :"#{prefix}bass", :pad].freeze, knobs: [knob].freeze, nodes: nodes, node: 1, code: code.freeze, error: nil,
                                 loose: [].freeze, hidden: { 'tees' => 40, 'arithmetic' => 21 }.freeze)
  end

  # The fake inspector with an amp envelope (a real one's snapshot: A 20
  # ms, D 300 ms, S 0.6, R 500 ms, -18..0 dB velocity) selected, its note
  # 0.1 s into the decay at peak 0.7 (+live+ false: no note), read at
  # monotonic time 0 (envelope-view-1).
  FAKE_ENVELOPE = MB::Sound.amp_env(0.02, 0.3, 0.6, 0.5)

  def ui_fake_envelope_inspector(live: true)
    info = ui_fake_inspector
    snap = Ractor.make_shareable(FAKE_ENVELOPE.param_snapshot)
    play = live ? { stage: :segment, segment: 1, position: 0.1, peak: 0.7, at: 0.0 }.freeze : nil
    env = UI::Inspect::NodeInfo.new(key: info.nodes.length, label: 'amp_env', role: 'env', count: 1, knobs: [].freeze, params: snap, preview: true, live: play,
                                    section: :amp, what: 'amp env', dest: ['amp'].freeze)
    info.with(nodes: [*info.nodes, env].freeze, node: info.nodes.length)
  end

  # The RENDER pane's source for the fake bass track: a small real synth
  # (a triangle voice, so captures move only when its few nodes change)
  # with a fixed phrase.
  # (Built once when this file loads: fake snapshots stay as quick to make
  # as before, which wall-clock examples like the heard-snapshot one count
  # on.  The synth is never sampled; previews build their own copy.)
  FAKE_CLIP = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::C4.n2).n8
  FAKE_SYNTH = MB::Sound::Synth.new(FAKE_CLIP.notes, voices: 2, seed: 1) { |v| v.hz.triangle.lp4(1200.hz) * v.amp_env * 0.5 }

  def ui_fake_render_source(track = :bass)
    UI::PatchRender::Source.new(track: track, synth: FAKE_SYNTH, clip: FAKE_CLIP, bpm: 128, bar_length: 1r, key: nil, tuning: nil,
                                channels: 2, note: nil, words: track.to_s, live: {}.freeze)
  end

  # A clip for the matrix: +notes+ as eighths from the start (nil: kit
  # rows +rows+), +name+, +bars+.
  def ui_fake_clip(name, notes, bars: 1r, rows: nil, ruby: nil, loop: true)
    ev = (rows || notes).each_with_index.map { |n, i|
      UI::NoteInfo.new(start: i * 1/8r, length: 1/8r, note: rows ? nil : n, velocity: i.zero? ? 1.0 : 0.7, row: rows ? n : nil,
                       marks: i.zero? ? [:accent].freeze : [].freeze)
    }.freeze
    UI::ClipInfo.new(name: name.to_s, kind: rows ? :kit : :seq, bars: bars, pattern: '', used: [].freeze, loop: loop, length: bars, events: ev,
                     ruby: ruby, range: rows ? nil : notes.min..notes.max, key: name.to_s)
  end

  # The clip matrix of the fake set: drums, bass, lead, pad over scenes
  # intro, drop, break (drop current), bass's next clip queued for 18:1,
  # pad's stop queued.  +prefix+ lengthens the names (text fitting).
  def ui_fake_matrix(prefix = '')
    kit = ui_fake_clip("#{prefix}beat_a", nil, rows: %i[kick snare kick hat kick snare kick hat])
    t = ->(name, state, playing, slots, queued = []) { UI::LaneInfo.new(name: :"#{prefix}#{name}", state: state, playing: playing, queued: queued.freeze, slots: slots.freeze, q: '1') }
    tracks = [
      t.(:drums, :playing, 0, [kit, ui_fake_clip("#{prefix}fill", nil, rows: %i[snare snare snare snare])]),
      t.(:bass, :playing, 0, [ui_fake_clip("#{prefix}bass_a", [36, 36, 43, 46, 36, 48, 46, 43], ruby: 'seq(C2, C2, G2, Bb2, C2, C3, Bb2, G2).n8.loop.named(:bass_a)'),
                              ui_fake_clip("#{prefix}bass_b", [41, 41, 48, 51]), ui_fake_clip("#{prefix}bass_1", [36])],
         [UI::LaunchInfo.new(seq: 10, kind: :launch, slot: 1, lands: '18:1', pos: 17r)]),
      t.(:lead, :stopped, nil, [ui_fake_clip("#{prefix}hook", [72, 74, 75, 79])]),
      t.(:pad, :playing, 0, [ui_fake_clip("#{prefix}chords", [60, 63, 67], bars: 2r)], [UI::LaunchInfo.new(seq: 9, kind: :stop, slot: nil, lands: '18:1', pos: 17r)]),
    ].freeze
    tn = ->(n) { :"#{prefix}#{n}" }
    scenes = [
      UI::SceneInfo.new(name: :"#{prefix}intro", cells: { tn.(:drums) => :stop, tn.(:bass) => 0, tn.(:lead) => :stop, tn.(:pad) => 0 }.freeze, current: false, queued: nil),
      UI::SceneInfo.new(name: :"#{prefix}drop", cells: { tn.(:drums) => 0, tn.(:bass) => 0, tn.(:lead) => 0, tn.(:pad) => 0 }.freeze, current: true, queued: nil),
      UI::SceneInfo.new(name: :"#{prefix}break", cells: { tn.(:drums) => 1, tn.(:bass) => 1, tn.(:lead) => :keep, tn.(:pad) => :stop }.freeze, current: false, queued: nil),
    ].freeze
    UI::MatrixInfo.new(tracks: tracks, scenes: scenes)
  end

  # One rack instance with two knobs (knobs :"bass/dub/space" and
  # :"bass/dub/tone" in ui_fake_rack_knobs).
  def ui_fake_racks(prefix = '')
    specs = { space: ui_knob_spec(:"#{prefix}space", 0.35, 0.0..1.0), tone: ui_knob_spec(:"#{prefix}tone", 2400.0, 600.0..8000.0, curve: :exp, unit: 'Hz') }.freeze
    [MB::Sound::Rack::RackInfo.new(
      name: :"#{prefix}dub", path: :"bass/#{prefix}dub", kind: :effect, signature: 'audio(sig) + audio(side) -> audio',
      ports: [{ name: :sig, type: :audio, role: :main, required: true }.freeze, { name: :side, type: :audio, role: :side, required: false }.freeze].freeze,
      latency: 72, knobs: [:"bass/#{prefix}dub/space", :"bass/#{prefix}dub/tone"].freeze, knob_specs: specs, slots: [].freeze
    )].freeze
  end

  # The rack knobs of ui_fake_racks as KnobValues.
  def ui_fake_rack_knobs(prefix = '')
    r = ui_fake_racks(prefix).first
    [UI::KnobValue.new(name: r.knobs[0], value: 0.6, spec: r.knob_specs[:space]),
     UI::KnobValue.new(name: r.knobs[1], value: 1800.0, spec: r.knob_specs[:tone])]
  end

  # Bus and send levels for the fake set's buses.
  def ui_fake_bus_levels
    lv = ->(peak, short) { UI::Levels.new(peak: [peak, peak - 1].freeze, rms: [short, short].freeze, short: short) }
    [
      { verb: UI::BusLevels.new(input: lv.(-14.0, -22.0), output: lv.(-12.5, -20.0)),
        drums: UI::BusLevels.new(input: lv.(-6.0, -15.0), output: lv.(-8.0, -16.0)) }.freeze,
      { [:pad, :verb] => UI::SendLevel.new(player: :pad, bus: :verb, gain: -12.0, level: lv.(-20.0, -28.0)) }.freeze,
    ]
  end

  # A full Snapshot at bar 17 beat 3 (+t+ seconds, +seq+), with a 440 Hz
  # scope of +scope_phase+.
  # +knobs+ adds the rack knobs' knobs (the :session captures).
  def ui_fake_snapshot(t: 1.0, seq: 1, scope_phase: 0.0, peak: -8.1, rack_knobs: false)
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
        *(rack_knobs ? ui_fake_rack_knobs : []),
      ].freeze,
      slow: ui_fake_slow,
      bus_levels: ui_fake_bus_levels[0],
      send_levels: ui_fake_bus_levels[1]
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
  # "real" terminal the screen owns, and a MB::Term::VT reading the master (what
  # the screen wrote), answering its queries.
  class FakeTerminal
    attr_reader :vt, :master, :slave

    def initialize(rows, cols)
      require 'pty'
      @master, @slave = PTY.open
      @slave.winsize = [rows, cols]
      @vt = MB::Term::VT.new(rows, cols, scrollback: 0)
      @lock = Mutex.new
      @bytes = 0
      @replies = [] # the last few [time, bytes] the VT answered (for #wait_input_idle's failures)
      @reader = Thread.new do
        loop do
          d = @master.readpartial(65_536)
          @lock.synchronize do
            @bytes += d.bytesize
            @vt.feed(d)
            r = @vt.take_replies
            unless r.empty?
              @replies << [MB::U.clock_now, r]
              @replies.shift while @replies.length > 8
              @master.write(r)
            end
          end
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    # Bytes the screen wrote so far.
    def bytes = @lock.synchronize { @bytes }

    # The terminal's last answers to the screen's queries, as text with
    # their ages ("\e[4;1R 2.31 s ago"), for failure messages.
    def recent_replies
      now = MB::U.clock_now
      @lock.synchronize { @replies.map { |t, r| format('%s %.2f s ago', r.inspect, now - t) } }
    end

    # Types +str+ a character at a time (as a person would).
    def type(str, delay: 0.002)
      str.each_char do |c|
        @master.write(c)
        sleep delay
      end
    end

    # Writes +str+ at once (an escape sequence, a paste).
    def write(str) = @master.write(str)

    # Waits until the screen's input thread has read everything written to
    # the terminal (nothing left unread on the slave side).  It may still
    # be handling the bytes: wait for what they do with wait_settled or
    # wait_for.  Returns true when drained within +timeout+.
    def wait_read(timeout: 5)
      deadline = MB::U.clock_now + timeout
      sleep 0.005 until unread == 0 || MB::U.clock_now > deadline
      unread == 0
    end

    # For random key walks: waits until the screen read what was written,
    # then for what it drew, at most +max+ seconds (a held note or a
    # sounding track keeps a meter moving for seconds, which a plain
    # #settle waits out: up to 3 s per key in tiles_keys_spec; test-speed-2).
    def read_and_settle(quiet: 0.05, max: 0.3)
      wait_read
      settle(quiet: quiet, timeout: max)
    end

    # FIONREAD (io/wait's #nread is gone in Ruby 4)
    FIONREAD = RUBY_PLATFORM.include?('darwin') ? 0x4004667F : 0x541B

    # Bytes written to the terminal that the screen hasn't read yet.
    def unread
      buf = [0].pack('l')
      @slave.ioctl(FIONREAD, buf)
      buf.unpack1('l')
    end

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

  # Waits for +tiles+' Router to reach +mode+ and the transition to finish:
  # the Router changes its state before the screen's #mode_changed pins the
  # focus and puts panes in, so a spec that reads the focus right after
  # seeing the new mode raced the input thread (tiles_keys_spec's F2 example
  # under load, 2026-10-18).  Reading under the screen's input lock waits
  # for the whole event.  Returns true when reached within +timeout+.
  def wait_mode(tiles, mode, timeout: 5)
    wait_settled(tiles, timeout: timeout) { tiles.router.mode == mode }
  end

  # Waits for +tiles+' input thread to have handled everything written to
  # +term+: the terminal's bytes all read, no escape sequence pending in
  # the decoder, and the thread waiting for input (not running or holding
  # the input lock), twice in a row.  A condition instead of a quiet
  # period: output never goes quiet while a pane animates, so
  # read_and_settle's 0.3 s cap ran out and late keys landed after the
  # spec moved on (tiles_keys_spec's walk under load, test-speed-3).
  # Returns true, or a String saying what wasn't idle (callers expect true).
  def wait_input_idle(tiles, term, timeout: 5)
    reader = tiles.instance_variable_get(:@reader)
    decoder = tiles.instance_variable_get(:@decoder)
    lock = tiles.instance_variable_get(:@input_lock)
    locked = -> { lock.respond_to?(:mon_locked?) ? lock.mon_locked? : lock.locked? }
    idle = -> { term.unread.zero? && !decoder.pending? && reader&.status == 'sleep' && !locked.call }
    return true if wait_until(timeout: timeout) { idle.call && (sleep(0.005); idle.call) }

    # Not idle: what was still going on, so the failure says (omnibus13:
    # tiles_keys_spec's walk timed out in 2 of 4 loaded suites without a
    # reason; a dead reader thread shows its exception)
    status = reader&.status
    died = nil
    if reader && !reader.alive?
      begin
        reader.value
      rescue Exception => e # rubocop:disable Lint/RescueException
        died = "#{e.class}: #{e.message} (#{e.backtrace&.first(3)&.join(' < ')})"
      end
    end
    "not idle after #{timeout} s: #{term.unread} bytes unread, decoder #{decoder.pending? ? 'pending' : 'clear'}, " \
      "reader #{status.inspect}#{died ? " (#{died})" : ''}#{reader&.alive? && status != 'sleep' ? " at #{reader.backtrace&.first(4)&.join(' < ')}" : ''}, " \
      "input lock #{locked.call ? 'held' : 'free'}" \
      "#{term.respond_to?(:recent_replies) && !term.recent_replies.empty? ? "; terminal replies: #{term.recent_replies.join(', ')}" : ''}"
  end

  # As #wait_until, with the block run under +tiles+' input lock (see
  # #wait_mode): for conditions on the mode and what it drives.
  def wait_settled(tiles, timeout: 5, &cond)
    lock = tiles.instance_variable_get(:@input_lock)
    wait_until(timeout: timeout) { lock.synchronize(&cond) }
  end

  # A Tiles screen on a FakeTerminal with a Pry of its own (prompt "t> "),
  # started with threads, its keyboard playing into NullKeyboardOut unless
  # +keyboard:+ is given.  Returns [tiles, terminal].
  def ui_tiles(layout = :tiles, rows: 30, cols: 100, **opts)
    require 'pry'
    opts[:keyboard] ||= MB::Sound::UI::Keyboard.new(out: NullKeyboardOut.new)
    term = FakeTerminal.new(rows, cols)
    # (Reline's history is per process: earlier examples' lines would be
    # what Up recalls after a recalled line)
    Reline::HISTORY.clear if defined?(Reline::HISTORY)
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
