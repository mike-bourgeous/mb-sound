require_relative '../../../../support/ui_helpers'

# The tuner's screens (hand-tune-3): NAV h opens ui :tuner in the tuner
# pane's keys, Enter picks the reference (step 2: the synths), Esc goes a
# step back, Enter on a synth runs its tune line (ui :tuning: the sound
# screen with the tune strip, the inspector's keys live), w in the
# inspector goes back to step 2; the layouts at 120x40 and 80x24; the
# strip names the inspector's keys from its keymap.  Synthetic references
# only, through a pty and a real Pry.
RSpec.describe(MB::Sound::UI::Panes::Tuner, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:wizard) { MB::Sound::HandTune::Wizard }

  before(:all) do
    @root = Dir.mktmpdir('tuner-ui-', SpecTmp::ROOT)
    refs = File.join(@root, 'refs')
    FileUtils.mkdir_p(refs)
    MB::Sound.write(File.join(refs, 'kick_sine.wav'), (110.hz.sine * MB::Sound.adsr(0.001, 0.2, 0, 0.05)).until(0.4), overwrite: true)
    MB::Sound.write(File.join(refs, 'snare_noise.wav'), (MB::Sound.noise * MB::Sound.adsr(0.001, 0.12, 0, 0.05)).until(0.3), overwrite: true)
  end

  before do
    @env = ENV.to_h.slice('MB_SOUND_TUNE_QUEUE', 'MB_SOUND_REFS', 'MB_SOUND_FITS')
    ENV['MB_SOUND_TUNE_QUEUE'] = File.join(@root, 'no-queue')
    ENV['MB_SOUND_REFS'] = File.join(@root, 'refs')
    ENV['MB_SOUND_FITS'] = File.join(Dir.mktmpdir('fits-', SpecTmp::ROOT), 'fits')
    wizard::Background.inline = true
    ui::TunerScreen.instance_variable_set(:@before, nil)
  end

  after do
    @tiles&.stop
    @term&.close
    ui.instance_variable_set(:@tiles, nil)
    wizard.close
    wizard::Background.inline = nil
    ui::Inspect.target = nil
    ui::Design.instance_variable_set(:@open, false)
    ui::Design.instance_variable_set(:@last, nil)
    ui::TunerScreen.instance_variable_set(:@before, nil)
    @session&.close
    MB::Sound.rewind
    %w[MB_SOUND_TUNE_QUEUE MB_SOUND_REFS MB_SOUND_FITS].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
  end

  def new_session
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false,
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 120))
  end

  # A screen on a pty of +rows+ x +cols+, made the UI's tiles (so `tuner`,
  # `design`, and `tune` switch its layout).
  def screen(rows, cols)
    @tiles, @term = ui_tiles(:tiles, rows: rows, cols: cols, session: new_session)
    ui.instance_variable_set(:@tiles, @tiles)
    expect(wait_until { @term.text.include?('t> ') }).to be_truthy
  end

  def key(bytes)
    @term.write(bytes)
    expect(wait_input_idle(@tiles, @term)).to eq(true)
  end

  # The screen as drawn after the background's jobs ran.
  def text
    @tiles.invalidate
    @tiles.refresh
    wizard.current&.background&.drain
    @tiles.invalidate
    @tiles.refresh
    @tiles.to_text
  end

  it 'opens on NAV h, picks a reference and a synth, goes back with Esc and w, and tunes through the tune line' do
    screen(40, 120)
    key("\x1d")
    expect(wait_mode(@tiles, :nav)).to eq(true)
    key('h')
    expect(@tiles.layout_name).to eq(:tuner)
    expect(wait_mode(@tiles, :pane)).to eq(true)
    expect(@tiles.tiler.focus).to eq(:tuner)
    t = text
    expect(t).to include('TUNER', '1 reference', '2 synth', '3 tune', 'kick_sine.wav', 'snare_noise.wav')
    expect(t).to match(/\d references: Enter pick/) # (2, and Samples other examples of this process read)
    expect(t).to match(/kick_sine\.wav\s+0\.40 s\s+A2 [+-]\d+ cents, percussive/)
    expect(t).to include(File.join(@root, 'refs', 'kick_sine.wav')) # (the picked one's path below)

    key("\r")
    w = wizard.current
    expect(w.state).to eq(:synth)
    expect(w.ref.name).to eq('kick_sine.wav')
    t = text
    expect(t).to include('kick_sine.wav', 'track :kick', 'synths on A2', 'init', 'blank', 'tr909')
    key("\e") # (a step back, still in the pane)
    expect(w.state).to eq(:reference)
    expect(@tiles.router.mode).to eq(:pane)
    key("\e") # (step 1: NAV)
    expect(wait_mode(@tiles, :nav)).to eq(true)
    key("\r")
    expect(wait_mode(@tiles, :pane)).to eq(true)
    key("\r")
    expect(w.state).to eq(:synth)

    # Down to the init voice (after the blank? init comes first: no fits yet)
    i = w.shown.index { |x| x.kind == :init }
    i.times { key("\e[B") }
    expect(w.under_cursor.kind).to eq(:init)
    expect(@tiles.send(:enter_hint)).to include('tune :kick with init against kick_sine.wav')
    key("\r")
    expect(wait_until { @tiles.layout_name == :tuning }).to eq(true)
    expect(w.state).to eq(:tuning)
    expect(w.tuned).to eq(:kick)
    expect(@session.arrangement.tracks.keys).to include(:kick, :kick_ref)
    expect(@tiles.tiler.focus).to eq(:inspector)
    expect(wait_mode(@tiles, :pane)).to eq(true)
    t = text
    expect(t).to include('TUNE', 'kick', 'kick_sine.wav', 'hearing the patch', 'b A/B', 'R refine', 'w synths', 'W references')
    # (the REPL shows the line it ran, shortened or whole)
    expect(wait_until { @term.text.include?('tune :kick, L.inst.init') }).to be_truthy

    key('w')
    expect(wait_until { @tiles.layout_name == :tuner }).to eq(true)
    expect(w.state).to eq(:synth)
    expect(text).to include('2 synth', 'init')
    key('q')
    expect(wizard.current).to be_nil
    expect(@tiles.layout_name).to eq(:tiles) # (back to the screen before)
  end

  it 'draws both steps and step 3 at 80x24, with the strip on one row' do
    screen(24, 80)
    MB::Sound::Session.with_context(session: @session) { ui::TunerScreen.open }
    expect(wait_until { @tiles.layout_name == :tuner }).to eq(true)
    t = text
    expect(t.lines.length).to eq(24)
    expect(t).to include('TUNER', 'kick_sine.wav', 'snare_noise.wav')
    expect(@tiles.tiler.layout.panes).to eq(%i[transport form tuner repl])
    w = wizard.current
    w.pick(w.refs.index { |r| r.name == 'snare_noise.wav' })
    t = text
    expect(t).to include('track :snare', 'synths on D2') # (a snare: its kit voice's note)
    expect(t.lines.map(&:rstrip).map(&:length).max).to be <= 80
    ui::TunerScreen.show(w)
    w.pick(w.shown.index { |x| x.name == :tr909 })
    expect(w.line).to eq("tune :snare, L.kit.tr909, ref: #{File.join(@root, 'refs', 'snare_noise.wav').inspect}, play: seq(D2).n4.loop")
    ui.run_line(w.line, @session)
    expect(@tiles.layout_name).to eq(:tuning)
    expect(@tiles.tiler.layout.panes).to eq(%i[transport form tune_strip inspector preview repl])
    t = text
    expect(t).to include(' TUNE ', 'snare', 'snare_noise.wav')
  end

  it 'names the inspector\'s hand-tune keys from its keymap, and every tuner key has help' do
    keys = ui::Panes::TuneStrip.keys
    expect(keys.map(&:first)).to eq(%w[b R A E # w W])
    expect(keys.map(&:last)).to all(satisfy { |h| !h.empty? })
    map = ui::Panes::Tuner.mode_keymap
    expect(map.entries.map(&:action).uniq).to include(:pick, :act, :audition, :ab, :find, :folder, :edit, :quit)
    expect(map.entries.reject { |b| b.respond_to?(:doc?) && b.doc? }.map(&:help)).to all(be_a(String))
    expect(ui::Keys::JUMPS[:tuner]).to eq('h')
    expect(ui::Keys.check_jumps({})).to eq([])
    expect(ui::Tiles.key_table.join("\n")).to include('the tuner (hand-tuning')
  end
end
