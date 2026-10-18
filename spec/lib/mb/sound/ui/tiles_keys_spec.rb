require_relative '../../../../support/ui_helpers'

# KEYS mode in the tiled console, headless (see tiles_spec.rb): a
# FakeTerminal types legacy bytes or kitty protocol sequences into the
# screen, whose virtual keyboard plays into a recorder or a real Session.
RSpec.describe('UI::Tiles KEYS mode', :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
    @session&.close
  end

  # Records what the keyboard sends.
  let(:out) do
    Class.new {
      attr_reader :log
      def initialize = @log = []
      def note_on(n, v, channel: 0, time: nil) = @log << [:on, n]
      def note_off(n, _v = nil, channel: 0, time: nil) = @log << [:off, n]
      def cc(i, v, channel: 0, time: nil) = @log << [:cc, i, v]
      def sounding = @log.each_with_object({}) { |(k, n), h| k == :on ? h[n] = true : k == :off ? h.delete(n) : nil }.keys
    }.new
  end

  def start(layout = :tiles, keyboard: MB::Sound::UI::Keyboard.new(out: out), **opts)
    @keyboard = keyboard
    @tiles, @term = ui_tiles(layout, keyboard: keyboard, **opts)
    expect(@term.wait_for('t> ')).to eq(true), @term.text
  end

  it 'starts the :keys layout in KEYS mode and plays with kitty press and release events' do
    start(:keys, keys_kitty: true)
    expect(@term.wait_for(' KEYS ')).to eq(true), @term.text
    expect(@tiles.router.mode).to eq(:grab)
    expect(@tiles.instance_variable_get(:@kitty_pushed)).to eq(true)
    expect(@keyboard.resolved_mode).to eq(:release)

    @term.write("\e[122;1:1u\e[99;1:1u")
    expect(wait_until { out.sounding.sort == [48, 52] }).to eq(true), out.log.inspect
    expect(@term.wait_for(/played C3 E3/)).to eq(true), @term.text
    @term.write("\e[122;1:2u\e[122;1:3u")
    expect(wait_until { out.sounding == [52] }).to eq(true), out.log.inspect

    # Ctrl-] (as the kitty protocol sends it) is NAV: notes off; i: the REPL
    @term.write("\e[93;5u")
    expect(@term.wait_for(' NAV ')).to eq(true)
    expect(out.sounding).to be_empty
    @term.write('i')
    expect(@term.wait_for(' REPL ')).to eq(true)
    expect(out.sounding).to be_empty
    expect(@tiles.instance_variable_get(:@kitty_pushed)).to eq(false)
    @term.type("6 * 7\r")
    expect(@term.wait_for('=> 42')).to eq(true)
  end

  it 'puts the keyboard pane in with NAV K, holds legacy keys while they repeat, and ends notes on every way out' do
    start
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('K')
    expect(@term.wait_for(' KEYS ')).to eq(true)
    expect(@tiles.tiler.layout.panes).to include(:keyboard)
    expect(@tiles.tiler.rects[:keyboard].h).to eq(8)
    expect(@keyboard.resolved_mode).to eq(:tap)
    expect(@term.text).to include('tap (no key-up)')
    @keyboard.off_mode = :hold # (notes that last until an exit)

    @term.type('zc')
    expect(wait_until { out.sounding.sort == [48, 52] }).to eq(true)
    # Ctrl-]: off in NAV; Ctrl-] again: back to KEYS; F2: the REPL
    @term.write("\x1d")
    expect(wait_settled(@tiles) { @tiles.router.mode == :nav && out.sounding.empty? }).to eq(true), out.log.inspect
    @term.write("\x1d")
    expect(wait_mode(@tiles, :grab)).to eq(true)
    @term.write("\eOQ")
    expect(wait_mode(@tiles, :repl)).to eq(true)

    # Ctrl-C in KEYS mode: off and back to the REPL (no interrupt)
    @tiles.keys
    @term.type('b')
    expect(wait_until { out.sounding == [55] }).to eq(true)
    @term.write("\x03")
    expect(wait_settled(@tiles) { @tiles.router.mode == :repl && out.sounding.empty? }).to eq(true), out.log.inspect

    # Ctrl-Z hides the tiles: off
    @tiles.keys
    @term.type('n')
    expect(wait_until { out.sounding == [57] }).to eq(true)
    @term.write("\x1a")
    expect(wait_until { @tiles.hidden? }).to eq(true)
    expect(out.sounding).to be_empty
    expect(@tiles.router.mode).to eq(:repl)

    # ui off (stop)
    @term.write("\x1a")
    expect(wait_until { @tiles.active? }).to eq(true)
    @tiles.keys
    @term.type('m')
    expect(wait_until { out.sounding == [59] }).to eq(true)
    @tiles.stop
    expect(out.sounding).to be_empty
  end

  # Up at the REPL prompt recalls +line+ (then clears the prompt again).
  def expect_history(line)
    @term.write("\e[A")
    expect(@term.wait_for(/t> #{Regexp.escape(line)}/)).to eq(true), @term.text
    @term.write("\x15") # Ctrl-U: an empty line again
    @term.settle(quiet: 0.1)
  end

  # Ctrl-] and back with +key+ (i or Enter): the REPL, not KEYS.
  def nav_round_trip(key)
    @term.write("\x1d")
    expect(wait_mode(@tiles, :nav)).to eq(true)
    @term.write(key)
    expect(wait_mode(@tiles, :repl)).to eq(true), "#{@tiles.router.mode} #{@tiles.tiler.focus}"
  end

  it 'recalls REPL history after every way into and out of KEYS mode, kitty sequences or not (ux-1 bug 2)' do
    start(:keys, keys_kitty: true)
    expect(@term.wait_for(' KEYS ')).to eq(true)
    pushes = -> { @tiles.instance_variable_get(:@kitty_pushed) }
    leave_ways = {
      ctrl_bracket_i: -> {
        @term.write("\e[93;5u")
        expect(wait_mode(@tiles, :nav)).to eq(true)
        @term.write('i')
      },
      f2: -> { @term.write("\e[1;1:1Q\e[1;1:3Q") },
      ctrl_c: -> { @term.write("\e[99;5u") },
      ctrl_z_and_back: -> {
        @term.write("\e[122;5u")
        expect(wait_until { @tiles.hidden? }).to eq(true)
        @term.write("\x1a")
        expect(wait_until { @tiles.active? }).to eq(true)
      },
    }
    enter_ways = {
      nav_k: -> { @term.write("\x1d"); expect(wait_mode(@tiles, :nav)).to eq(true); @term.write('K') },
      f2: -> { @term.write("\eOQ") },
      ruby: -> { @tiles.keys },
    }

    # Leave the start's KEYS mode and put a line in the history
    leave_ways[:ctrl_bracket_i].call
    expect(wait_mode(@tiles, :repl)).to eq(true)
    @term.type("40 + 2\r")
    expect(@term.wait_for('=> 42')).to eq(true)

    n = 0
    enter_ways.each do |how_in, enter|
      leave_ways.each do |how_out, leave|
        enter.call
        expect(wait_settled(@tiles) { @tiles.router.mode == :grab && pushes.call }).to eq(true), "#{how_in}: #{@tiles.router.mode}"
        # Kitty presses, repeats, and releases of arrows and notes (velocity in KEYS)
        @term.write("\e[1;1:1A\e[1;1:2A\e[1;1:3A\e[122;1:1u\e[122;1:3u")
        leave.call
        expect(wait_settled(@tiles) { @tiles.router.mode == :repl && !pushes.call }).to eq(true), "#{how_in}/#{how_out}: #{@tiles.router.mode}"
        expect(@tiles.tiler.focus).to eq(:repl)
        expect(out.sounding).to be_empty
        nav_round_trip(n.even? ? 'i' : "\r")
        n += 1
        expect_history('40 + 2')
        # What a terminal that kept the kitty flags would send still recalls
        @term.write("\e[1;1:1A")
        expect(@term.wait_for(/t> 40 \+ 2/)).to eq(true), "#{how_in}/#{how_out}: #{@term.text}"
        @term.write("\x15")
        @term.settle(quiet: 0.1)
      end
    end

    # ui off pops the flags too
    @tiles.keys
    expect(wait_until { pushes.call }).to eq(true)
    @tiles.stop
    expect(pushes.call).to eq(false)
  end

  it 'keeps the mode invariants through random key sequences, and the REPL works after any of them' do
    rng = Random.new(RSpec.configuration.seed)
    start(:keys, keys_kitty: true)
    @keyboard.off_mode = :hold
    steps = {
      nav: "\x1d", nav_kitty: "\e[93;5u", p: 'p', k_jump: 'K', t_jump: 't', i: 'i', enter: "\r", ctrl_c: "\e[99;5u", legacy_ctrl_c: "\x03",
      ctrl_z: "\x1a", note: "\e[122;1:1u", note_legacy: 'x', z: 'z', esc: "\e", digit: -> { rng.rand(1..7).to_s },
      ruby_keys: -> { @tiles.keys; nil }, ruby_off: -> { @tiles.keys(false); nil },
      # (round 3: window prefix, overlay, palette, F2, a pane shown over the REPL's slot)
      ctrl_w: "\x17", ctrl_w_l: "\x17l", ctrl_w_p: "\x17p", question: '?', colon: ':', f2: "\eOQ",
      show_on_repl: -> { @tiles.show(:knobs, at: :repl) if @tiles.tiler.layout.panes.include?(:repl); nil },
    }
    path = []
    40.times do
      name, key = steps.to_a.sample(random: rng)
      path << name
      key = key.call if key.respond_to?(:call)
      @term.write(key) if key
      @term.settle(quiet: 0.05)
      expect(@tiles.mode_problems).to eq([]), "#{path.join(' ')}: #{@tiles.mode_problems.inspect}"
    end
    # Back to the REPL from wherever the walk ended
    @term.write("\x1a") if @tiles.hidden?
    @tiles.keys(false)
    @tiles.router.mode = :repl
    expect(wait_settled(@tiles) { @tiles.active? && @tiles.router.mode == :repl }).to eq(true)
    @term.write("\x03") # Ctrl-C: whatever the walk typed (maybe several lines: ? and : are Ruby) goes
    @term.settle(quiet: 0.1)
    @term.write("\x05\x15") # Ctrl-E Ctrl-U
    @term.settle(quiet: 0.1)
    @term.type("6 * 7\r")
    expect(@term.wait_for('=> 42')).to eq(true), "#{path.join(' ')}\n#{@term.text}"
  end

  it 'switches between the REPL and KEYS with F2 (legacy and kitty bytes), and `keys` enters KEYS (ux-1 item 15)' do
    start(keys_kitty: true)
    @term.write("\eOQ") # F2 (legacy)
    expect(wait_mode(@tiles, :grab)).to eq(true)
    expect(@tiles.tiler.layout.panes).to include(:keyboard)
    @term.write("\e[12~") # F2 (tilde form) back
    expect(wait_mode(@tiles, :repl)).to eq(true)
    expect(@tiles.tiler.focus).to eq(:repl)
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles)
    expect(MB::Sound.keys).to equal(@tiles)
    expect(@tiles.router.mode).to eq(:grab)
    @term.write("\e[1;1:1Q\e[1;1:3Q") # F2 press and release in the kitty protocol
    expect(wait_mode(@tiles, :repl)).to eq(true)
    expect(@tiles.mode_problems).to eq([])
  ensure
    MB::Sound::UI.instance_variable_set(:@tiles, nil)
  end

  it "captures into every armed track that builds, naming a broken patch's track and line in the messages (ux-1 item 17)" do
    ev = MB::Sound::MIDI::Event
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false,
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    events = [ev.parse([0x90, 60, 90], time: 0.1r), ev.parse([0x80, 60, 64], time: 0.3r)]
    @session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
    live = MB::Sound.live?
    MB::Sound.live = true
    broken_line = __LINE__ + 2
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:l_bass, q: 1) { |c| c.equal?(MB::Sound::Arrangement::PatchCheck.probe) ? c.number : c.synth { |v| v.nosuch_patch_method } } # (passes the definition check)
      MB::Sound.track(:lead, q: 1) { |c| c.synth { |v| v.hz.ramp * v.amp_env } }
      expect { MB::Sound.arm(:l_bass) }.to output(/l_bass can't monitor/).to_stdout # (live: at the prompt; see Arrangement::PatchCheck)
      MB::Sound.arm(:lead)
    end
    50.times { @session.process_buffer }
    session = @session
    out = Object.new
    out.define_singleton_method(:target_session) { session }
    %i[note_on note_off cc].each { |m| out.define_singleton_method(m) { |*, **| nil } }
    start(keyboard: MB::Sound::UI::Keyboard.new(out: out))
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles) # (UI.screen: the live warning goes to the messages)
    # (and to stderr too: this screen isn't the console's terminal)
    expect { @tiles.send(:capture_keys) }.to output(/capture into :l_bass failed/).to_stderr
    # The painter has seen the error (it opened the pane) after the capture's
    # own flash, and kept that flash: the order a slower machine always
    # gets, which once replaced it (see messages_spec)
    @tiles.refresh
    expect(@tiles.tiler.layout.panes).to include(:messages)
    150.times { @session.process_buffer } # to the launch point
    expect(@session.arrangement.captures.keys).to eq([:lead_1])
    msg = MB::Sound::UI.messages.recent(1)[0]
    expect(msg.severity).to eq(:error)
    expect(msg.text).to match(/capture into :l_bass failed: NoMethodError: undefined method 'nosuch_patch_method'.* \(at spec\/lib\/mb\/sound\/ui\/tiles_keys_spec\.rb:#{broken_line}\)/)
    expect(@tiles.instance_variable_get(:@flash)[0]).to match(/\Acapture: what you played loops into :lead at \d+:\d.*; :l_bass failed \(m: messages\)\z/)
  ensure
    MB::Sound.live = live unless live.nil?
    MB::Sound::UI.instance_variable_set(:@tiles, nil)
    MB::Sound::UI.messages.clear
  end

  it 'builds a clip in step entry and puts its Ruby on the REPL line' do
    start(context: MB::Sound.module_eval('binding'))
    @tiles.keys(step: true)
    expect(@term.wait_for(' STEP ')).to eq(true)
    @term.type('z', delay: 0.15)
    @term.type('x', delay: 0.15)
    @term.type('3', delay: 0.15)
    @term.type('c', delay: 0.15)
    expect(@term.wait_for('seq(C3, D3, E3.n4).n8')).to eq(true), @term.text
    @term.write("\r")
    expect(@term.wait_for(' REPL ')).to eq(true)
    expect(@term.wait_for('t> seq(C3, D3, E3.n4).n8')).to eq(true), @term.text
    @term.type("\r")
    expect(@term.wait_for(/=> #<Seq\(n2: 48@0\+n8, 50@1\/8\+n8, 52@1\/4\+n4\)>/)).to eq(true), @term.text
    expect(@keyboard.clip.to_ruby).to eq('seq(C3, D3, E3.n4).n8')
    expect(out.sounding).to be_empty
  end

  it 'plays an armed track and captures what was played into a clip, through the Session MIDI input' do
    transport = MB::Sound::Sequence::Transport.new(bpm: 240)
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: 512), transport: transport, realtime: true)
    keyboard = MB::Sound::UI::Keyboard.new(out: MB::Sound::UI::Keyboard::Link.new(session: @session, patch: nil), off_mode: :tap)
    keyboard.out.attach # (so arm doesn't warn about missing live MIDI where there is none)
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:lead, q: 1) { |c| c.synth(voices: 2) { |v| v.hz.ramp * v.amp_env } }
      MB::Sound.arm(:lead)
    end
    start(keyboard: keyboard)
    @tiles.keys
    expect(@term.wait_for(' KEYS ')).to eq(true)
    expect(wait_until { @session.players.key?(:'lead/live') }).to eq(true)
    @term.type('z', delay: 0.12)
    @term.type('c', delay: 0.12)
    @term.type('b', delay: 0.12)
    expect(wait_until { @session.midi_log.length >= 6 }).to eq(true), @session.midi_log.inspect
    expect(@session.midi_log.map { |r| r[3][0..1] }.select { |b| b[0] == 0x90 }.map(&:last)).to eq([48, 52, 55])

    @term.write("\r") # capture
    expect(wait_until(timeout: 6) { @session.arrangement.captures.key?(:lead_1) }).to eq(true), @term.text
    clip = @session.arrangement.captures[:lead_1]
    expect(@term.wait_for(/capture: what you played loops into :lead at \d+:\d/)).to eq(true), @term.text
    expect(clip.events.map(&:value)).to eq([48, 52, 55])

    # Step entry's w swaps the clip so far into the armed track (a journaled change)
    lead_changes = -> { @session.journal.changes.count { |e| e.subject == :lead } }
    before = lead_changes.call
    @tiles.keys(step: true)
    expect(@term.wait_for(' STEP ')).to eq(true)
    @term.type('v', delay: 0.15)
    @term.type('w', delay: 0.15)
    expect(wait_until { lead_changes.call > before }).to eq(true), @term.text
    expect(@keyboard.clip.to_ruby).to eq('seq(F3).n8.loop')
    expect(@term.wait_for('swap: seq(F3).n8.loop loops into :lead')).to eq(true), @term.text
  end
end
