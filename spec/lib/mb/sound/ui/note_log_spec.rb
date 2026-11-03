require_relative '../../../../support/ui_helpers'

# UI notes (ui-scaffold-1, u-notes): `ui.note 'text'` appends the text with
# the screen, what plays, and the last console lines to the day's Markdown
# file; NAV # opens a prompt for one on the tiles, keeping the screen as it
# was when the prompt opened; `ui.notes` lists the day's.
RSpec.describe(MB::Sound::UI::NoteLog, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    @dir = tmp_path('ui-notes')
    @env = ENV['MB_SOUND_UI_NOTES']
    ENV['MB_SOUND_UI_NOTES'] = @dir
  end

  after do
    ENV['MB_SOUND_UI_NOTES'] = @env
    @tiles&.stop
    @term&.close
    @session&.close
    MB::Sound.rewind
  end

  it 'appends notes with what plays and the last commands to one file a day, and lists them' do
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    take = MB::Sound::Take.new(session: @session)
    allow(MB::Sound::Take).to receive(:active).and_return(take)
    b = MB::Sound::Take.console_binding
    MB::Sound::Session.with_context(session: @session) do
      take.line('track :bass, :dnb_sub', b)
      take.line('bg :bass, seq(E1, G1).n8.loop', b)
    end
    4.times { @session.process_buffer }

    time = Time.new(2026, 10, 30, 14, 3, 12)
    n = described_class.save("the cutoff turns too slowly\nat the bottom of its range", session: @session, time: time,
                             capture: { layout: :sound, focus: :inspector, mode: :pane, size: [120, 40], text: "SOUND\n▸lp4  cutoff ████" })
    expect(n.path).to eq(File.join(@dir, '2026-10-30.md'))
    expect(n.to_s).to eq("ui.note saved 14:03:12 (ui :sound, 120x40, focus inspector, pane mode) to #{n.path}, data #{n.data}")
    expect(n.data).to start_with(File.join(@dir, 'data', '')).and end_with('/140312.json')
    text = File.read(n.path)
    expect(text).to start_with("# UI notes 2026-10-30\n")
    expect(text).to include('## 14:03:12  the cutoff turns too slowly', '> at the bottom of its range',
                            '- **screen**: ui :sound, 120x40, focus inspector, pane mode', '- **at**: bar ', ':bass (track ',
                            "track :bass, :dnb_sub  # ", "bg :bass, seq(E1, G1).n8.loop  # ", "````text\nSOUND\n▸lp4  cutoff ████\n````")

    described_class.save('second', session: nil, time: time + 60, capture: { layout: nil, focus: nil, mode: :off, size: nil, text: nil })
    after = File.read(n.path)
    expect(after).to start_with(text) # (append-only)
    expect(after.scan('# UI notes').length).to eq(1)
    expect(after).to include("## 14:04:12  second\n\n- **screen**: no screen\n- **playing**: no session")

    list = described_class.list(Date.new(2026, 10, 30))
    expect(list.entries).to eq([['14:03:12', 'the cutoff turns too slowly'], ['14:04:12', 'second']])
    expect(list.to_s).to start_with("2 UI notes on 2026-10-30 (#{n.path}):\n  14:03:12  the cutoff turns too slowly")
    expect(described_class.list('2026-10-29').to_s).to start_with('No UI notes on 2026-10-29')
    expect { described_class.save('  ') }.to raise_error(ArgumentError, /takes the note's text/)
  end

  # (the maintainer, 2026-10-31: "The ui.note feature should save somewhere
  # the container can see")
  it 'defaults to the main checkout\'s tmp/ui-notes from a git checkout, else the user data directory; the env wins' do
    expect(described_class.dir).to eq(@dir)
    ENV['MB_SOUND_UI_NOTES'] = nil
    main = MB::Sound::Internal.main_checkout(MB::Sound::Internal::GEM_ROOT)
    expect(main).not_to be_nil
    expect(described_class.dir).to eq(File.join(main, 'tmp', 'ui-notes'))
    expect(File.directory?(File.join(main, '.git'))).to eq(true) # (the main checkout, also from a worktree)

    allow(MB::Sound::Internal).to receive(:checkout_tmp_dir).and_return(nil)
    expect(described_class.dir).to eq(File.join(File.dirname(MB::Sound::Internal.help_data_dir), 'ui-notes'))
  end

  # audio-safety-2: the maintainer's first ui.note of a session glitched
  # the audio; finding tmp/ui-notes ran `git rev-parse`, and starting a
  # process from a big Ruby process holds the GVL through fork (19 ms of
  # render-thread wait measured on Linux; longer on macOS, which forks)
  it 'never starts a process, also for the first note of a session' do
    internal = MB::Sound::Internal
    had = internal.instance_variable_defined?(:@checkout_tmp_dir)
    old = internal.instance_variable_get(:@checkout_tmp_dir)
    old_version = MB::Sound::GraphIO.instance_variable_get(:@library_version)
    internal.remove_instance_variable(:@checkout_tmp_dir) if had
    MB::Sound::GraphIO.instance_variable_set(:@library_version, nil)
    ENV['MB_SOUND_UI_NOTES'] = nil
    %i[spawn fork].each { |m| allow(Process).to receive(m).and_raise("no #{m} on a live path") }
    allow(Kernel).to receive(:fork).and_raise('no fork on a live path')
    allow(IO).to receive(:popen).and_raise('no popen on a live path')
    allow(Open3).to receive(:spawn).and_raise('no spawn on a live path') # (Open3 calls Kernel#spawn on itself)
    expect { Open3.capture2('true') }.to raise_error(/no spawn/) # (the old lookup's path is covered)

    expect(described_class.dir).to eq(File.join(internal.main_checkout(internal::GEM_ROOT), 'tmp', 'ui-notes'))
    expect(MB::Sound::GraphIO.library_version).to match(/\A#{Regexp.escape(MB::Sound::VERSION)} \(\h{7}\)\z/)
  ensure
    if had
      internal.instance_variable_set(:@checkout_tmp_dir, old)
    elsif internal.instance_variable_defined?(:@checkout_tmp_dir)
      internal.remove_instance_variable(:@checkout_tmp_dir)
    end
    MB::Sound::GraphIO.instance_variable_set(:@library_version, old_version)
  end

  it 'finds the main checkout and the commit as git does, from git\'s files' do
    internal = MB::Sound::Internal
    root = internal::GEM_ROOT
    common = IO.popen(['git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'], err: File::NULL, &:read).strip
    head = IO.popen(['git', '-C', root, 'rev-parse', 'HEAD'], err: File::NULL, &:read).strip
    expect(internal.git_dirs(root)[1]).to eq(common)
    expect(internal.git_dirs(File.join(root, 'lib', 'mb'))[1]).to eq(common)
    expect(internal.main_checkout(root)).to eq(File.dirname(common))
    expect(internal.git_head(root, length: 40)).to eq(head)
    expect(internal.main_checkout('/')).to be_nil
    expect(internal.git_head('/')).to be_nil
  end

  it 'reads what plays from the UI snapshot while a screen is up (no render lock)' do
    slow = ui::Slow.new(
      tracks: [ui::TrackInfo.new(name: :bass, q: '1/4r', clip: 'bass_a', armed: false), ui::TrackInfo.new(name: :pad, q: '1r', clip: 'graph', armed: false)].freeze,
      scenes: [].freeze, scene: :drop, queued: [].freeze, recording: [].freeze, armed: [].freeze, form: nil, knob_specs: {}.freeze
    )
    snap = ui::Snapshot.fake(bar: 17, beat: 3r, bpm: 128, slow: slow, parts: [
      ui::PartLoad.new(name: :bass, kind: :player, state: :playing, load: 0.01),
      ui::PartLoad.new(name: :hat, kind: :player, state: :starting, load: 0.0),
      ui::PartLoad.new(name: :master, kind: :master, state: :playing, load: 0.0),
    ].freeze)
    session = double('session', ui_feed: double('feed', latest: snap))
    expect(session).not_to receive(:players)
    expect(described_class.playing_lines(session)).to eq([
      '- **at**: bar 17:3, 128 bpm, scene :drop',
      '- **players**: :bass (track: bass_a, q 1/4r); :hat (starting)',
      '- **tracks not playing**: :pad',
    ])
  end

  it 'is ui.note and ui.notes with no screen too, and a help entry' do
    n = ui.facade.note('works without a screen')
    expect(n.where).to eq('no screen')
    expect(ui.facade.notes.entries.map(&:last)).to eq(['works without a screen'])
    expect(ui::HelpIndex.named('note').map(&:label)).to include('ui.note')
    expect(ui::HelpIndex.named('notes').map(&:label)).to include('ui.notes')
  end

  # NAV # on the tiles: a prompt line, the screen kept as it was when it
  # opened, the note saved on Enter
  it 'takes a note from a prompt line on the tiles (NAV #)' do
    @term = UIHelpers::FakeTerminal.new(24, 80)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:sound), input: @term.slave, output: @term.slave, repl: :none,
                           probe: false, size: [24, 80], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @tiles.start(thread: false)
    @tiles.refresh(0.0)
    feed = ->(bytes) { @term.write(bytes); 10.times { @tiles.pump(0.01) }; @tiles.refresh(0.0) }
    feed.("\x1d") # (Ctrl-]: NAV)
    feed.('#')
    expect(@tiles.to_text.lines.last).to include('ui note: ')
    feed.('knob rows are too dim')
    feed.("\r")
    list = described_class.list
    expect(list.entries.map(&:last)).to eq(['knob rows are too dim'])
    text = File.read(list.path)
    expect(text).to include('- **screen**: ui :sound, 80x24', 'SOUND') # (the screen as it was)
    expect(text).not_to include('ui note: knob') # (not the prompt line)
  end
end
