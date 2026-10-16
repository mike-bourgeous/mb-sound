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

  def wait_until(timeout: 5)
    deadline = MB::U.clock_now + timeout
    sleep 0.01 until yield || MB::U.clock_now > deadline
    yield
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

    # Ctrl-] (as the kitty protocol sends it) leaves: notes off, back to the REPL
    @term.write("\e[93;5u")
    expect(@term.wait_for(' REPL ')).to eq(true)
    expect(out.sounding).to be_empty
    expect(@tiles.instance_variable_get(:@kitty_pushed)).to eq(false)
    @term.type("6 * 7\r")
    expect(@term.wait_for('=> 42')).to eq(true)
  end

  it 'puts the keyboard pane in with NAV p, holds legacy keys while they repeat, and ends notes on every way out' do
    start
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('p')
    expect(@term.wait_for(' KEYS ')).to eq(true)
    expect(@tiles.tiler.layout.panes).to include(:keyboard)
    expect(@tiles.tiler.rects[:keyboard].h).to eq(8)
    expect(@keyboard.resolved_mode).to eq(:hold)
    expect(@term.text).to include('(no key-up)')

    @term.type('zc')
    expect(wait_until { out.sounding.sort == [48, 52] }).to eq(true)
    # Ctrl-]: off, and back in from NAV with p
    @term.write("\x1d")
    expect(wait_until { @tiles.router.mode == :repl && out.sounding.empty? }).to eq(true), out.log.inspect

    # Ctrl-C in KEYS mode: off and back to the REPL (no interrupt)
    @tiles.keys
    @term.type('b')
    expect(wait_until { out.sounding == [55] }).to eq(true)
    @term.write("\x03")
    expect(wait_until { @tiles.router.mode == :repl && out.sounding.empty? }).to eq(true), out.log.inspect

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
    expect(clip.events.map(&:value)).to eq([48, 52, 55])
  end
end
