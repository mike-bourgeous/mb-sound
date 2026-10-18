# Guard spec for console help (design/notes/help.md): names in topics and on
# the sheet exist, every example plays in level bounds, every lesson runs,
# and every console command is covered by a topic, the sheet, or an
# exemption with a reason (Help::Coverage).
require 'stringio'
require 'open3'
require 'mb/sound/help'

RSpec.describe MB::Sound::Help do
  let(:index) { MB::Sound::Help.index }

  # Every name help may call: console commands, DSL methods, Numeric
  # mixins, and public methods of MB::Sound classes and modules (clip,
  # Notes, Session methods called on values in examples).
  def self.known_names
    @known_names ||= begin
      index = MB::Sound::Help.index
      names = index.console_methods.map(&:name) + index.dsl_methods.map(&:name) + index.numeric_methods
      names += ObjectSpace.each_object(Module).select { |m| m.name&.start_with?('MB::Sound') }.flat_map { |m| m.public_instance_methods(false) rescue [] }
      names.uniq
    end
  end

  # Help state goes to a temp dir; the monitor trim (process-wide, set by
  # the level) is restored after each example
  around do |ex|
    old = ENV['MB_SOUND_HELP_DIR']
    old_trim = MB::Sound::Session.monitor_gain
    ENV['MB_SOUND_HELP_DIR'] = tmp_path('help')
    ex.run
  ensure
    ENV['MB_SOUND_HELP_DIR'] = old
    MB::Sound::Session.monitor_gain = old_trim
  end

  # A NullOutput that keeps a copy of everything written to it.
  let(:recording_output) {
    Class.new(MB::Sound::NullOutput) {
      def written = @written ||= []
      def write(data)
        written << data.map(&:dup)
        super
      end
    }.new(channels: 2, sleep: false)
  }

  def written(output) = output.written.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }

  def new_session(master_gain: MB::Sound::Session::DEFAULT_MASTER_GAIN, output: nil, monitor: nil)
    MB::Sound::Session.new(
      master_gain: master_gain, output: output || MB::Sound::NullOutput.new(channels: 2, sleep: false),
      transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 800,
      realtime: false, raise_errors: true, monitor: monitor
    )
  end

  # Plays +bars+ bars (120 BPM); returns the output channels.
  def play_bars(session, bars)
    bufs = Array.new((96000 * bars) / 800) { session.process_buffer(800).map(&:dup) }
    bufs.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }
  end

  def peak_db(channels) = 20 * Math.log10([channels.map { |c| c.abs.max }.max, 1e-9].max)

  def loudness(channels) = MB::Sound.loudness(channels.map { |c| Numo::DFloat.cast(c) }, true_peak: false).integrated

  # The level check tone's loudness at the reference level (the yardstick
  # for examples).
  def self.reference
    @reference ||= begin
      s = nil
      s = MB::Sound::Session.new(master_gain: MB::Sound::Session::DEFAULT_MASTER_GAIN, output: MB::Sound::NullOutput.new(channels: 2, sleep: false),
        transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
      MB::Sound::Help::Level::SessionPlayer.new(s).start(MB::Sound::Help::Level::REFERENCE_DB)
      out = Array.new(240) { s.process_buffer(800).map(&:dup) }.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }
      {
        peak: 20 * Math.log10(out.map { |c| c.abs.max }.max),
        loudness: MB::Sound.loudness(out.map { |c| Numo::DFloat.cast(c) }, true_peak: false).integrated,
      }
    ensure
      s&.close
    end
  end

  describe 'topics' do
    MB::Sound::Help::TOPICS.each_value do |topic|
      it "#{topic.name}: lists only real methods" do
        expect((topic.commands - index.console_methods.map(&:name)) - %i[now help lesson]).to eq([])
        expect(topic.names - self.class.known_names).to eq([])
      end

      it "#{topic.name}: renders" do
        text = MB::U.remove_ansi(MB::Sound::Help.topic_page(topic.name).to_s)
        expect(text).to include(topic.title)
        expect(text).not_to include('stale help entry')
      end

      topic.examples.each_with_index do |ex, i|
        if ex.sound
          it "#{topic.name}: example #{i + 1} (#{ex.title}) plays near the reference level" do
            session = new_session
            out = MB::Sound::Session.with_context(session: session) do
              MB::Sound::Help::Try.run(ex, out: StringIO.new)
              play_bars(session, ex.bars + 1)
            end
            ref = self.class.reference
            # Peaks scale with the chosen level, as the tone does: at most
            # EXAMPLE_PEAK_OVER_TONE_DB over it at any level
            expect(peak_db(out) - ref[:peak]).to be <= MB::Sound::Help::Level::EXAMPLE_PEAK_OVER_TONE_DB
            expect(loudness(out)).to be_within(MB::Sound::Help::Level::EXAMPLE_LOUDNESS_WINDOW).of(ref[:loudness])
          ensure
            session&.close
          end
        else
          it "#{topic.name}: example #{i + 1} (#{ex.title}) runs" do
            session = new_session
            MB::Sound::Session.with_context(session: session) do
              expect { MB::Sound::Help::Try.run(ex, out: StringIO.new) }.not_to raise_error
            end
          ensure
            session&.close
          end
        end
      end
    end

    it 'has unique example titles per topic and known groups' do
      MB::Sound::Help::TOPICS.each_value do |t|
        expect(t.examples.map(&:title).uniq.length).to eq(t.examples.length)
        expect(MB::Sound::Help::GROUPS).to have_key(t.group)
      end
    end
  end

  describe 'sheet' do
    MB::Sound::Help::Sheet::SHEET.each do |group, lines|
      it "#{group}: calls only real methods" do
        # Stand-ins for your own graphs and clips, and form section names
        placeholders = %i[g b l r bass2 beat intro verse outro]
        expect(lines.flat_map(&:call_names).uniq - self.class.known_names - placeholders).to eq([])
      end
    end

    [80, 110, 160].each do |w|
      it "fits one screen at #{w} columns" do
        allow(MB::U).to receive(:width).and_return(w)
        lines = MB::Sound.help.to_s.lines.map { |l| MB::U.remove_ansi(l.chomp) }
        expect(lines.map(&:length).max).to be <= w
        expect(lines.length).to be <= 48 if w >= 110
      end
    end
  end

  it "loads with the first help, now, or lesson in a plain script (no require 'mb/sound/help')" do
    code = <<~RUBY
      require 'mb/sound'
      print MB::Sound.const_defined?(:Help, false), ' '
      print MB::Sound.help(:knobs).class, ' ', MB::Sound.method(:lesson).owner
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__), '-e', code, chdir: File.dirname(tmp_path('script')))
    expect(status.success?).to eq(true), err
    expect(out).to eq('false MB::Sound::Help::TopicPage MB::Sound::HelpMethods')
  end

  describe 'lessons' do
    # Notes on a stand-in keyboard, two a bar for +bars+ bars.
    def keyboard(bars)
      ev = MB::Sound::MIDI::Event
      events = (0...(bars * 2)).flat_map { |i|
        t = i.to_r
        n = [57, 60, 64, 67][i % 4]
        [ev.parse([0x90, n, 90], time: t + 0.1r), ev.parse([0x80, n, 64], time: t + 0.6r)]
      }
      MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
    end

    before do
      allow(MB::Sound::Take).to receive(:data_dir).and_return(tmp_path('takes'))
      allow_any_instance_of(MB::Sound::Take).to receive(:home).and_return(nil)
    end

    MB::Sound::Help::LESSONS.each_value do |lesson|
      it "#{lesson.name}: every step's check fails before its code and passes after" do
        session = new_session
        session.midi_in.input = keyboard(30) if lesson.needs.include?(:midi)
        MB::Sound::Session.with_context(session: session) do
          runner = MB::Sound::Help::LessonRunner.new(lesson, 0)
          play_bars(session, 1)
          lesson.steps.each do |step|
            expect(runner.step).to equal(step)
            expect(step.passed?).to eq(false), "step #{step.title.inspect} passes before its code runs" if step.check
            MB::Sound.instance_exec(&step.code) if step.code
            expect(step.passed?).to eq(true), "step #{step.title.inspect}: #{step.check_text} failed"
            expect(runner.after_line).to include('✓')
            play_bars(session, 1)
          end
          expect(runner.done?).to eq(true)
          expect(peak_db(play_bars(session, 2)) - self.class.reference[:peak]).to be <= MB::Sound::Help::Level::EXAMPLE_PEAK_OVER_TONE_DB
        end
      ensure
        session&.close
      end
    end

    it 'lesson.back stays on a step that already passes until lesson.next (it used to move on at once)' do
      session = new_session
      lesson = MB::Sound::Help::LESSONS[:set]
      MB::Sound::Session.with_context(session: session) do
        runner = MB::Sound::Help::LessonRunner.new(lesson, 0)
        first = runner.step
        MB::Sound.instance_exec(&first.code)
        expect(runner.after_line).to include('✓')
        expect(runner.index).to eq(1)

        runner.back
        expect(runner.step).to equal(first)
        expect(first.passed?).to eq(true)
        expect(runner.after_line).to be_nil # the line that went back doesn't undo it
        expect(runner.index).to eq(0)
        expect(MB::U.remove_ansi(runner.to_s)).to include('already done')

        runner.next
        expect(runner.index).to eq(1)
      end
    ensure
      session&.close
    end

    it 'record: files the lesson makes go to the help directory, never the take directory' do
      takes = tmp_path('takes')
      session = new_session
      session.midi_in.input = keyboard(30)
      lesson = MB::Sound::Help::LESSONS[:record]
      MB::Sound::Session.with_context(session: session) do
        MB::Sound::Help::LessonRunner.active = runner = MB::Sound::Help::LessonRunner.new(lesson, 0)
        lesson.steps.each do |step|
          MB::Sound.instance_exec(&step.code)
          expect(runner.after_line).to include('✓')
          play_bars(session, 1)
        end
      end
      paths = session.recordings.map(&:path)
      session.close
      dir = File.join(ENV['MB_SOUND_HELP_DIR'], 'lessons', 'record')
      expect(paths.length).to eq(1)
      expect(File.dirname(paths[0])).to eq(dir)
      expect(Dir.exist?(takes) ? Dir.children(takes) : []).to eq([])
    ensure
      MB::Sound::Help::LessonRunner.active = nil
      session&.close
    end

    it "record: the capture step doesn't pass when capture failed, even once the rec's loop adds to captures" do
      session = new_session
      session.midi_in.input = keyboard(0) # no keyboard: nothing played
      lesson = MB::Sound::Help::LESSONS[:record]
      MB::Sound::Session.with_context(session: session) do
        runner = MB::Sound::Help::LessonRunner.new(lesson, 0)
        2.times { MB::Sound.instance_exec(&runner.step.code); runner.after_line }
        play_bars(session, 5) # the rec 2 closes: captures has :l_keys_1
        expect(MB::Sound.captures).to include(:l_keys_1)
        expect(runner.step.title).to eq('Capture what you played')
        MB::Sound.live = true
        expect { MB::Sound.instance_exec(&runner.step.code) }.to output(/Nothing played/).to_stderr
        expect(runner.step.passed?).to eq(false)
        expect(runner.after_line).to be_nil
      ensure
        MB::Sound.live = false
      end
    ensure
      session&.close
    end

    it "flow: uses its own scene names and won't start over a playing form" do
      session = new_session
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.track(:drums, q: 1) { |c| c.tone.ramp * c.gate }
        MB::Sound.scene(:intro, drums: MB::Sound.seq(MB::Sound::C3).n4.loop)
        MB::Sound.scene(:outro, drums: MB::Sound.seq(MB::Sound::C2).n4.loop)
        mine = session.arrangement.scenes.slice(:intro, :outro)
        MB::Sound.flow { intro 4; outro 4 }
        play_bars(session, 1)

        expect { MB::Sound.lesson(:flow, restart: true) }.to raise_error(RuntimeError, /lesson :flow plays its own form.*finish/)
        expect { MB::Sound.lesson(:set, restart: true) }.to raise_error(RuntimeError, /lesson :set plays its own form/)
        expect(MB::Sound::Help::LessonRunner.active).to be_nil
        expect(MB::Sound.lesson(:knobs, restart: true)).to be_a(MB::Sound::Help::LessonRunner) # knobs don't touch the set

        # Its steps never touch the song's scenes
        MB::Sound.instance_exec(&MB::Sound::Help::LESSONS[:flow].steps.first.code)
        expect(session.arrangement.scenes.slice(:intro, :outro)).to eq(mine)
      ensure
        MB::Sound::Help::LessonRunner.active = nil
      end
    ensure
      session&.close
    end

    it 'lists the lessons once the active one is done' do
      lesson = MB::Sound::Help::LESSONS[:knobs]
      MB::Sound::Help::LessonRunner.active = MB::Sound::Help::LessonRunner.new(lesson, lesson.steps.length)
      expect(MB::Sound.lesson).to be_a(MB::Sound::Help::LessonList)
      expect(MB::Sound::Help::LessonRunner.active).to be_nil
    ensure
      MB::Sound::Help::LessonRunner.active = nil
    end

    it 'declares every (state, event) pair of a lesson run' do
      r = MB::Sound::Help::LessonRunner
      r::STATES.each do |st|
        expect(r::TABLE[st].keys).to eq(r::EVENTS)
        r::EVENTS.each { |ev| expect(r::STATES).to include(r.next_state(st, ev)) }
      end
      expect { r.next_state(:asleep, :quit) }.to raise_error(ArgumentError, /Unknown lesson state/)
    end

    it "resumes a run in this console and Session, starts over in a new one, and keeps completion apart (ux-r3 item 34)" do
      lesson = MB::Sound::Help::LESSONS[:knobs]
      runs = MB::Sound::Help::LessonRunner.runs
      runs.delete(:knobs)
      session = new_session
      MB::Sound::Session.with_context(session: session) do
        runner = MB::Sound.lesson(:knobs)
        expect(runner.index).to eq(0)
        runner.next
        runner.next
        expect { runner.quit }.to output(/left knobs at step 3 .*resumes it in this console/).to_stdout
        expect(runner.state).to eq(:left)

        again = MB::Sound.lesson(:knobs)
        expect(again).to equal(runner)
        expect([again.index, again.state]).to eq([2, :running])
        expect(MB::U.remove_ansi(MB::Sound::Help::LessonList.new.to_s)).to match(/:knobs .*step 3\/5/)

        # A new console (no runs): step 1; nothing saved per step
        runs.clear
        expect(MB::Sound.lesson(:knobs).index).to eq(0)
        expect(MB::Sound::Help::History.completed?(lesson)).to eq(false)

        # Finished: remembered across consoles, shown as done before, and
        # a new run starts at step 1
        r = MB::Sound.lesson(:knobs)
        lesson.steps.length.times { r.next }
        expect(r.state).to eq(:done)
        expect(MB::Sound::Help::History.completed?(lesson)).to eq(true)
        runs.clear
        expect(MB::U.remove_ansi(MB::Sound::Help::LessonList.new.to_s)).to match(/:knobs .*5 steps ✓ done before/)
        expect(MB::Sound.lesson(:knobs).index).to eq(0)
      end
      # Another Session: starts over
      other = new_session
      MB::Sound::Session.with_context(session: other) { expect(MB::Sound.lesson(:knobs).session).to equal(other) }
    ensure
      MB::Sound::Help::LessonRunner.active = nil
      MB::Sound::Help::LessonRunner.runs.clear
      session&.close
      other&.close
    end

    it 'reads finished lessons from progress files written before ux-r3 (name => next step)' do
      lesson = MB::Sound::Help::LESSONS[:knobs]
      FileUtils.mkdir_p(MB::Sound::Help::History.dir)
      File.write(MB::Sound::Help::History.path, JSON.generate(knobs: lesson.steps.length, set: 1))
      expect(MB::Sound::Help::History.completed?(lesson)).to eq(true)
      expect(MB::Sound::Help::History.completed?(MB::Sound::Help::LESSONS[:set])).to eq(false)
    ensure
      File.delete(MB::Sound::Help::History.path) rescue nil
    end

    it 'starts at a later step with from:, replaying the steps before it' do
      session = new_session
      lesson = MB::Sound::Help::LESSONS[:knobs]
      MB::Sound::Session.with_context(session: session) do
        runner = nil
        expect { runner = MB::Sound.lesson(:knobs, from: 3) }.to output(/replaying step 1: .*\n.*replaying step 2: /).to_stdout
        expect(runner.index).to eq(2)
        expect(lesson.steps[0].passed?).to eq(true)
        expect(lesson.steps[1].passed?).to eq(true)
        expect { MB::Sound.lesson(:knobs, from: 9) }.to raise_error(ArgumentError, /from: is a step number of lesson :knobs \(1..5\)/)
      end
    ensure
      MB::Sound::Help::LessonRunner.active = nil
      MB::Sound::Help::LessonRunner.runs.clear
      session&.close
    end

    it 'starts from the console command' do
      MB::Sound::Help::LessonRunner.active = nil
      expect(MB::Sound.lesson).to be_a(MB::Sound::Help::LessonList)
      expect(MB::Sound.lesson(:set, restart: true).index).to eq(0)
      expect(MB::Sound.lesson).to be_a(MB::Sound::Help::LessonRunner)
      expect { MB::Sound.lesson(:sett) }.to raise_error(ArgumentError, /:set/)
    ensure
      MB::Sound::Help::LessonRunner.active = nil
    end
  end

  describe 'level' do
    # Records what the level check asks of the player.
    let(:player) {
      Class.new {
        attr_reader :log
        def initialize = @log = []
        def start(db) = @log << [:start, db]
        def level=(db)
          @log << [:level, db]
        end
        def stop = @log << [:stop]
      }.new
    }

    def calibrate(keys, start_db: nil)
      out = StringIO.new
      opts = { input: StringIO.new(keys), out: out, player: player }
      opts[:start_db] = start_db if start_db
      [MB::Sound::Help::Level::Calibration.new(**opts).run, MB::U.remove_ansi(out.string)]
    end

    it 'starts at the reference and saves nothing before a check' do
      expect(MB::Sound::Help::Level.saved).to be_nil
      expect(MB::Sound::Help::Level.db).to eq(-30)
      expect(MB::U.remove_ansi(MB::Sound.help.level(input: StringIO.new).to_s)).to include('no level check yet')
    end

    it 'moves in 3 dB steps with up/down (arrows or +/-) and 1 dB with left/right, and saves on Enter' do
      db, text = calibrate("\e[A\e[A+\e[D-\r")
      expect(db).to eq(-30 + 9 - 1 - 3)
      expect(MB::Sound::Help::Level.saved).to eq(-25)
      expect(player.log).to eq([[:start, -30], [:level, -27], [:level, -24], [:level, -21], [:level, -22], [:level, -25], [:stop]])
      expect(text).to include('level -25 dBFS: monitor trim +5 dB')
    end

    it 'cancels with q (or Escape, Ctrl-C, end of input), keeping the saved level' do
      MB::Sound::Help::Level.save(-20)
      expect(calibrate("++q").first).to be_nil
      expect(calibrate("++\e").first).to be_nil
      expect(calibrate("++\x03").first).to be_nil
      expect(calibrate("++").first).to be_nil
      expect(MB::Sound::Help::Level.saved).to eq(-20)
      expect(player.log.last).to eq([:stop])
    end

    it 'stays in range and resets to the reference with r' do
      expect(calibrate('+' * 40 + "\r").first).to eq(MB::Sound::Help::Level::RANGE.end)
      expect(calibrate('-' * 40 + "\r").first).to eq(MB::Sound::Help::Level::RANGE.begin)
      expect(calibrate("++r\r", start_db: -50).first).to eq(-30)
    end

    it 'sets the level directly' do
      expect(MB::U.remove_ansi(MB::Sound.help.level(-18.db).to_s)).to include('-18.0 dBFS').and include('monitor trim +12.0 dB')
      expect(MB::Sound::Help::Level.db).to eq(-18)
      expect(MB::Sound::Help::Level.save(5)).to eq(MB::Sound::Help::Level::RANGE.end)
    end

    it 'turns the saved level into the monitor trim' do
      expect(MB::Sound::Help::Level.trim_for(-30)).to be_within(1e-12).of(1)
      MB::Sound::Help::Level.save(-18)
      expect(MB::Sound::Session.monitor_gain.to_db).to be_within(1e-9).of(12)
      MB::Sound::Session.monitor_gain = 1
      expect(MB::Sound::Help::Level.apply.to_db).to be_within(1e-9).of(12)
      expect(MB::Sound::Help::Level.save(-3)).to eq(-3)
      expect(MB::Sound::Session.monitor_gain.to_db).to be_within(1e-9).of(27)
    end

    it 'plays the level check tone at the asked peak through a monitored Session, and restores the trim' do
      MB::Sound::Session.monitor_gain = 2.db
      out = recording_output
      session = new_session(output: out, monitor: true)
      p = MB::Sound::Help::Level::SessionPlayer.new(session)
      p.start(-30)
      play_bars(session, 1)
      expect(peak_db(written(out))).to be_within(0.3).of(-30)
      p.level = -18
      out.written.clear
      expect(peak_db(play_bars(session, 1))).to be_within(0.3).of(-30) # the mix before the trim
      expect(peak_db(written(out))).to be_within(0.3).of(-18)
      p.stop
      play_bars(session, 0.1)
      expect(session.players).not_to have_key(MB::Sound::Help::Level::PLAYER)
      expect(MB::Sound::Session.monitor_gain.to_db).to be_within(1e-9).of(2)
    ensure
      session&.close
    end

    it 'saves and applies the level on Enter, and restores the old trim on cancel' do
      MB::Sound::Session.monitor_gain = 1
      session = new_session(monitor: true)
      player = MB::Sound::Help::Level::SessionPlayer.new(session)
      MB::Sound::Help::Level::Calibration.new(input: StringIO.new("++q"), out: StringIO.new, player: player).run
      expect(MB::Sound::Session.monitor_gain).to eq(1)
      MB::Sound::Help::Level::Calibration.new(input: StringIO.new("++\r"), out: StringIO.new, player: player).run
      expect(MB::Sound::Session.monitor_gain.to_db).to be_within(1e-9).of(6)
    ensure
      session&.close
    end

    describe 'first launch' do
      let(:tty) { StringIO.new("\r").tap { |io| def io.tty? = true } }

      it 'runs before the prompt in a terminal with a sound card; Enter keeps the default' do
        out = StringIO.new
        expect(MB::Sound::Help.first_level_check(input: tty, out: out, output_type: :device, player: player)).to eq(-30)
        expect(MB::Sound::Help::Level.saved).to eq(-30)
        expect(MB::U.remove_ansi(out.string)).to include('First launch')
        expect(player.log.first).to eq([:start, -30])
      end

      it 'skips without a terminal, without a sound card, when asked to, or once there is a level' do
        expect(MB::Sound::Help.first_level_check(input: StringIO.new("\r"), out: StringIO.new, output_type: :device, player: player)).to be_nil
        expect(MB::Sound::Help.first_level_check(input: tty, out: StringIO.new, output_type: :null, player: player)).to be_nil
        begin
          ENV['MB_SOUND_LEVEL_CHECK'] = '0'
          expect(MB::Sound::Help.first_level_check(input: tty, out: StringIO.new, output_type: :device, player: player)).to be_nil
        ensure
          ENV.delete('MB_SOUND_LEVEL_CHECK')
        end
        MB::Sound::Help::Level.save(-24)
        expect(MB::Sound::Help.first_level_check(input: tty, out: StringIO.new, output_type: :device, player: player)).to be_nil
        expect(player.log).to eq([])
      end

      it 'skips with a note if the output fails' do
        bad = Object.new.tap { |o| def o.start(_) = raise(IOError, 'no device'); def o.stop = nil }
        out = StringIO.new
        expect(MB::Sound::Help.first_level_check(input: tty, out: out, output_type: :device, player: bad)).to be_nil
        expect(out.string).to include('Level check skipped')
      end
    end
  end

  describe 'pages' do
    def text(x) = MB::U.remove_ansi(x.to_s)

    it 'shows a method with its signature, aliases, and topics' do
      t = text(MB::Sound.help(:turn))
      expect(t).to include('turn(').and include('help :knobs')
      expect(text(MB::Sound.help(:move))).to include('alias of turn')
    end

    it 'shows console commands and node methods of the same name' do
      t = text(MB::Sound.help(:reverb))
      expect(t).to include('node method')
    end

    it 'searches names and doc comments with a Regexp' do
      t = text(MB::Sound.help(/reson/))
      expect(t).to include('matches').and include('lp4')
    end

    it 'lists matching topics first in a search (help /sq80/)' do
      t = text(MB::Sound.help(/sq80/))
      expect(t).to include('Topics').and include(':sq80').and include('SQ-80 voice and patches')
      expect(t).to include('sq80_patches').and include('sq80_env')
      expect(t.index(':sq80 ')).to be < t.index('sq80_patches')
    end

    it 'keeps code spans whole when wrapping topic text' do
      expect(text(MB::Sound.help(:sq80))).not_to include('`')
    end

    it 'falls back to a search for unknown names' do
      expect(text(MB::Sound.help(:xyzzy_nothing))).to include('0 matches')
    end

    it 'lists topics by group and answers topic names as methods' do
      expect(text(MB::Sound.help.topics)).to include('Perform').and include(':knobs')
      expect(text(MB::Sound.help.knobs)).to include('Knobs and snapshots')
      expect { MB::Sound.help.knobz }.to raise_error(NoMethodError) { |e| expect(e.detailed_message).to include('knobs') }
    end

    it 'gives a random runnable tip' do
      tip = MB::Sound.help.tip(random: Random.new(1))
      expect(text(tip)).to include('tip').and include('play it: help(:')
      expect(tip.example).to be_a(MB::Sound::Help::Topic::Example)
    end

    it 'explains a graph' do
      g = 110.hz.saw.at(-20.db).lp4(800)
      t = text(MB::Sound.help(g))
      expect(t).to include('as Ruby').and include('lp4').and include('help :filters')
    end

    it 'refuses example numbers out of range' do
      expect { MB::Sound.help(:knobs).try(3) }.to raise_error(ArgumentError, /2 examples/)
      expect { MB::Sound.help(:analysis).try }.to raise_error(ArgumentError, /no examples/)
    end
  end

  describe 'formatting (ux-1 items 22-27)' do
    def text(x) = MB::U.remove_ansi(x.to_s)

    # Runs of more than +limit+ non-blank lines that aren't code (indented
    # 4 or more): what reads as a wall of text.
    def walls(page, limit: 9)
      runs = text(page).lines.map(&:chomp).slice_when { |a, b| a.strip.empty? != b.strip.empty? }
      runs.reject { |r| r.first.strip.empty? }.map { |r| r.reject { |l| l.start_with?('    ') } }.select { |r| r.length > limit }
    end

    it 'leaves no wall of text on any topic, section, method, list, or search page' do
      pages = MB::Sound::Help::TOPICS.keys.map { |t| [t, MB::Sound.help(t)] }
      pages += MB::Sound::Help::GROUPS.keys.map { |g| [g, MB::Sound.help(g)] }
      names = MB::Sound::Help::TOPICS.values.flat_map(&:names).uniq
      pages += names.map { |n| [n, MB::Sound.help(n)] }
      pages += [[:sheet, MB::Sound.help], [:topics, MB::Sound.help.topics], [:search, MB::Sound.help(/reverb/)], [:lessons, MB::Sound::Help::LessonList.new]]
      bad = pages.filter_map { |name, page| w = walls(page); "#{name}: #{w.first.first(2).join(' / ')} (#{w.first.length} lines)" unless w.empty? }
      expect(bad).to eq([])
    end

    it 'wraps at most 100 columns and prints plain under NO_COLOR or to a pipe' do
      allow(MB::U).to receive(:width).and_return(200)
      t = MB::Sound.help(:ui).to_s
      expect(text(t).lines.map { |l| l.chomp.length }.max).to be <= 100
      expect(MB::Sound::Help.for_output(t, StringIO.new)).not_to include("\e[")
      tty = StringIO.new
      def tty.tty? = true
      expect(MB::Sound::Help.for_output(t, tty)).to include("\e[")
      ENV['NO_COLOR'] = '1'
      expect(MB::Sound::Help.for_output(t, tty)).not_to include("\e[")
    ensure
      ENV.delete('NO_COLOR')
    end

    it 'lists the sheet footer one command per line, lessons near the top, and sections in the headings' do
      lines = text(MB::Sound.help).lines.map(&:chomp)
      expect(lines[1]).to start_with('Learn: lesson :set')
      foot = lines.drop(lines.index('More help') + 1).reject(&:empty?)
      expect(foot.length).to eq(MB::Sound::Help::Sheet::FOOTER.length)
      foot.each { |l| expect(l).to match(/\A  \S+( \S+)? +\S/) }
      expect(lines.join("\n")).to include('Perform help :perform')
    end

    it 'opens a section in detail (help :perform)' do
      t = text(MB::Sound.help(:perform))
      expect(t).to include('On the sheet', 'Knobs and snapshots  help :knobs', 'lesson :knobs', 'Also on the sheet')
      expect(text(MB::Sound.help.perform)).to eq(t)
    end

    it 'points method pages to the lessons that use them' do
      expect(text(MB::Sound.help(:turn))).to match(/Learn it in: lesson :knobs \(step \d+ of \d+\)/)
      expect(MB::Sound::Help.lessons_using([:capture]).map(&:first)).to include(:record)
    end

    it 'lists every layout on help :ui, the one on screen marked, and the keys from the screen\'s own table (ux-1 item 25)' do
      MB::Sound.layout(:spec_mine) { cols { pane :transport; pane :meters } }
      band = MB::Sound::UI::Band.new(layout: MB::Sound::UI.layouts[:deck], io: StringIO.new, size: [30, 100])
      allow(MB::Sound::UI).to receive(:screen).and_return(band)
      t = text(MB::Sound.help(:ui))
      %i[band deck mini tiles studio keys wall spec_mine].each { |n| expect(t).to include("ui :#{n}") }
      expect(t).to include('* ui :deck', '--ui :show', 'defined with layout')
      expect(t).to include('pick a pane by its number', 'capture into the armed tracks')
    ensure
      MB::Sound::UI.layouts.delete(:spec_mine)
    end

    it 'sets lesson steps apart with blank lines and a "lesson :x · step n/m" line' do
      allow(MB::Sound::Help::History).to receive(:load).and_return({})
      allow(MB::Sound::Help::History).to receive(:complete)
      t = text(MB::Sound::Help::LessonRunner.new(MB::Sound::Help::LESSONS[:set]))
      expect(t).to start_with("\nlesson :set · step 1/")
      expect(t).to end_with("\n")
      expect(t).to include('waiting for:')
    end
  end

  describe 'now' do
    def text(x) = MB::U.remove_ansi(x.to_s)

    it 'suggests a start when nothing plays' do
      session = new_session
      MB::Sound::Session.with_context(session: session) do
        t = text(MB::Sound.now)
        expect(t).to include('now').and include('start something').and include('lesson')
      end
    ensure
      session&.close
    end

    it 'shows players, knobs, scenes, the form, and queued changes mid-set, with commands for them' do
      session = new_session
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.instance_exec do
          knob :n_cut, 400, range: 100..8000, curve: :exp, unit: 'Hz'
          track(:n_bass, q: 1) { |c| c.tone.ramp.lp4(knob(:n_cut)) * c.amp_env }
          scene :intro, n_bass: seq(MB::Sound::A1, rest).n8.loop
          scene :verse, n_bass: seq(MB::Sound::A1, MB::Sound::A2).n8.loop
          go :intro
        end
        play_bars(session, 1)
        MB::Sound.turn(:n_cut, 4000, over: 2.bars)
        MB::Sound.go(:verse, in: 4.bars)
        play_bars(session, 1)
        t = text(MB::Sound.now)
        expect(t).to include(':n_bass').and include(':n_cut').and include('→').and include('scenes')
        expect(t).to include('queued').and include('scene :verse').and include('▶verse').and include('undo')
        expect(t).to include('turn :n_cut')
      end
    ensure
      session&.close
    end
  end

  describe 'welcome' do
    it 'is a few lines plus one runnable tip' do
      t = MB::U.remove_ansi(MB::Sound::Help.welcome(random: Random.new(3)))
      expect(t).to include('help').and include('now').and include('tip').and include('play it')
      # (the welcome itself; the tip is drawn from every topic's examples,
      # so its length depends on the seed and the topics: 3-13 lines)
      head = t.lines.take_while { |l| !l.start_with?('tip ') }
      expect(head.length).to be <= 20
      expect(t.lines.length - head.length).to be <= 13
    end

    it 'lists one command per line in groups, descriptions aligned, the same formatter as the sheet\'s footer (ux-1 r3 item 1)' do
      t = MB::U.remove_ansi(MB::Sound::Help.welcome(random: Random.new(3))).lines.map(&:chomp)
      expect(t).to include('Learn', 'Play', 'Help')
      cmds = MB::Sound::Help::WELCOME.flat_map { |_, pairs| pairs }
      rows = cmds.map { |cmd, what| t.find { |l| l.start_with?("  #{cmd} ") && l.end_with?(what) } }
      expect(rows).to all(be_a(String))
      expect(rows.map { |r| r.index(r.strip.split(/  +/).last) }.uniq.length).to eq(1) # (one description column)
      expect(rows.map(&:length).max).to be <= 80
      # Plain to a pipe (or NO_COLOR)
      expect(MB::Sound::Help.welcome(io: StringIO.new)).not_to include("\e[")
    end

    it 'mentions the level check until there is one, then the monitor trim' do
      expect(MB::U.remove_ansi(MB::Sound::Help.welcome)).to include('help.level sets a comfortable')
      MB::Sound::Help::Level.save(-24)
      t = MB::U.remove_ansi(MB::Sound::Help.welcome)
      expect(t).not_to include('sets a comfortable')
      expect(t).to include('monitor trim +6 dB')
    end
  end

  describe 'help and lesson as console commands (ux-1 item 28)' do
    def text(x) = MB::U.remove_ansi(x.to_s)
    let(:b) { g = 110.hz.saw.lp4(800); binding.tap { g } }

    it 'reads what follows help as words, Ruby literals, or names in the console' do
      expect(text(MB::Sound::Help.page_for_text(''))).to include('one-screen sheet')
      expect(text(MB::Sound::Help.page_for_text('flow'))).to include('help :flow')
      expect(text(MB::Sound::Help.page_for_text(':turn'))).to include('turn(')
      expect(text(MB::Sound::Help.page_for_text('turn'))).to include('turn(')
      expect(text(MB::Sound::Help.page_for_text('/reson/'))).to include('help /reson/')
      expect(text(MB::Sound::Help.page_for_text('g', b))).to include('lp4')
      expect(text(MB::Sound::Help.page_for_text('perform'))).to include('On the sheet')
      expect(text(MB::Sound::Help.page_for_text('the knobs'))).to include('help :knobs')
      expect(text(MB::Sound::Help.page_for_text('xyzzy plugh'))).to include('0 matches')
      # Item 29: mixing an effect in, by any of its names
      ['mix an effect in', 'wet', 'dry', ':wet', 'how do i mix in reverb'].each do |q|
        expect(text(MB::Sound::Help.page_for_text(q))).to include('help :blend'), q
      end
      expect(text(MB::Sound.help(:dry))).to include('beat.blend(0.4) { |s|')
    end

    it 'runs as Pry commands, leaving help(...) and lesson.next to Ruby' do
      require 'pry'
      commands = Pry::CommandSet.new.import(Pry::Commands)
      commands.rename_command('pry-help', 'help')
      MB::Sound::Help.install_commands(commands)
      expect(commands.find_command('help mix an effect in')).not_to be_nil
      expect(commands.find_command('help(:knobs).try')).to be_nil
      expect(commands.find_command('help.topics')).to be_nil
      expect(commands.find_command('lesson set')).not_to be_nil
      expect(commands.find_command('lesson.next')).to be_nil
      out = StringIO.new
      pry = Pry.new(output: out, commands: commands, target: b)
      pry.eval('help flow')
      expect(out.string).to include('help :flow')
      expect(out.string).not_to include("\e[")
    end
  end

  describe 'Pry setup' do
    it "moves Pry's help to pry-help and prints pages as text" do
      require 'pry'
      commands = Pry::CommandSet.new.import(Pry::Commands)
      config = Pry.config
      allow(config).to receive(:commands).and_return(commands)
      old_print = config.print
      hooks = Pry::Hooks.new
      allow(config).to receive(:hooks).and_return(hooks)
      MB::Sound::Help.install_pry!
      expect(commands.valid_command?('pry-help')).to eq(true)
      expect(commands.valid_command?('help')).to eq(true) # mb-sound's, taking free text (ux-1 item 28)
      expect(commands['help'].description).to start_with('mb-sound help')
      expect(commands.valid_command?('lesson')).to eq(true)
      out = StringIO.new
      config.print.call(out, MB::Sound.help.topics, nil)
      expect(out.string).not_to start_with('=>')
      expect(hooks.hook_exists?(:after_eval, :mb_sound_lesson)).to eq(true)
    ensure
      config.print = old_print if old_print
    end
  end

  describe 'coverage guard' do
    it 'covers every console command with a topic, the sheet, or an exemption' do
      expect(MB::Sound::Help::Coverage.uncovered).to eq([])
    end

    it 'exempts only real modules and methods' do
      names = index.console_methods.map(&:name)
      expect(MB::Sound::Help::Coverage::EXEMPT.keys - names).to eq([])
      expect(MB::Sound::Help::Coverage::EXEMPT_MODULES.keys.reject { |m| Object.const_get(m) rescue false }).to eq([])
    end
  end
end
