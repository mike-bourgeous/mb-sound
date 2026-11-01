require_relative '../../../support/ui_helpers'

# Console commands and UI panes start no processes while a Session plays
# (audio-safety-2, 2026-11-01): a fork holds the GVL, so the render thread
# can't write (a session's first ui.note ran `git rev-parse`).  The spawn
# guard (spec/support/spawn_guard.rb) fails any example where library code
# starts one while a render thread runs; this one walks the live paths a
# set uses with one running.
RSpec.describe('live paths start no processes', :aggregate_failures) do
  include UIHelpers

  let(:ui) { MB::Sound::UI }

  before do
    @notes = ENV['MB_SOUND_UI_NOTES']
    ENV['MB_SOUND_UI_NOTES'] = nil
    @help = ENV['MB_SOUND_HELP_DIR']
    ENV['MB_SOUND_HELP_DIR'] = File.join(tmp_path('help'), 'help')
    @tmp_dir = MB::Sound::Internal.instance_variable_get(:@checkout_tmp_dir)
    @version = MB::Sound::GraphIO.instance_variable_get(:@library_version)
    @trim = MB::Sound::Session.monitor_gain
  end

  after do
    ENV['MB_SOUND_UI_NOTES'] = @notes
    ENV['MB_SOUND_HELP_DIR'] = @help
    MB::Sound::Internal.instance_variable_set(:@checkout_tmp_dir, @tmp_dir)
    MB::Sound::GraphIO.instance_variable_set(:@library_version, @version)
    MB::Sound::Session.monitor_gain = @trim
    @tiles&.stop
    @term&.close
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound.rewind
  end

  it 'the guard sees a process started from library code while a Session plays' do
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual))
    MB::Sound.bg(:try, 220.hz.sine.at(-30.db))
    Thread.pass until MB::Sound::Session.default.running?
    # (code that says it is library code: the guard keys on lib/mb/ frames)
    eval("Open3.capture2('true')", binding, '/somewhere/lib/mb/sound/fake_live_path.rb', 1) # rubocop:disable Security/Eval
    expect(SpawnGuard.take).to eq(['spawn `true` from lib/mb/sound/fake_live_path.rb:1 (block (2 levels) in <top (required)>)'])
  end

  it 'walks notes, help, the master and monitor commands, saving, and every tiled layout drawn from the live Session' do
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual))
    MB::Sound.bg(:try, 220.hz.sine.at(-30.db))
    session = MB::Sound::Session.default
    Thread.pass until session.running?
    expect(SpawnGuard.live?).to eq(true)

    # A session's first note: where notes go, found fresh (then written to
    # this example's directory, not the checkout's tmp/)
    MB::Sound::Internal.remove_instance_variable(:@checkout_tmp_dir) if MB::Sound::Internal.instance_variable_defined?(:@checkout_tmp_dir)
    MB::Sound::GraphIO.instance_variable_set(:@library_version, nil)
    expect(ui::NoteLog.dir).to end_with('ui-notes')
    ENV['MB_SOUND_UI_NOTES'] = tmp_path('ui-notes')
    note = ui.facade.note('a note while it plays') # (ui.note: `MB::Sound.ui` alone would show the band)
    expect(note.path).to start_with(tmp_path('ui-notes'))
    ui.facade.notes
    expect(MB::Sound::GraphIO.library_version).to start_with(MB::Sound::VERSION)

    MB::Sound.help.to_s
    MB::Sound.help(:mixing).to_s
    MB::Sound.help.level(input: StringIO.new).to_s
    MB::Sound.master
    MB::Sound.monitor_gain(-6.db)
    MB::Sound.players
    expect(SpawnGuard.take).to eq([])

    # Every tiled layout, drawn from the live Session's feed and Poll
    @term = UIHelpers::FakeTerminal.new(50, 170)
    %i[tiles studio session mixer sound].each do |name|
      @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(name), input: @term.slave, output: @term.slave, repl: :none, probe: false, size: [50, 170],
                             keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
      @tiles.start(thread: false)
      3.times { |i| @tiles.refresh(i * 0.3) }
      ui::NoteLog.capture(@tiles)
      @tiles.stop
      @tiles = nil
      expect(SpawnGuard.take).to eq([]), "layout #{name}"
    end
  end
end
