require_relative 'player/items'

module MB
  module Sound
    # bin/play.rb's player (play-ui-1, 2026-11-02; the maintainer: "I'd like
    # to see bin/play.rb adopt the tiled UI, choosing as appropriate for
    # file type", then "Add to the play.rb work: keyboard seeking and
    # volume controls, spacebar play/pause"): plays files one after
    # another, each on a fresh background Session from the start of its
    # timeline, on a terminal screen chosen by the file's type
    # (UI.show_layouts :player_audio, :player_module, :player_midi,
    # :player), or as plain lines without a terminal or with ui: false.
    #
    #     MB::Sound::Player.new(['a.flac', 'tune.mod']).run
    #
    # Every file ends by one rule (PlaybackEnd).  The keys (UI::Keys::
    # PLAYER_SCREEN; ? lists them) act through #act: Space pauses (the
    # Session's fading pause; the frames carry on exactly), Left/Right seek
    # a little (SEEK_SECONDS, or a bar in a module), Up/Down a lot
    # (JUMP_SECONDS, or a section), - and + turn the monitor trim
    # (VOLUME_STEP_DB, at most 0 dB: Session::MonitorTrim), n/p the next and
    # previous file, Home the start, q quits.
    class Player
      # Seconds Left/Right move in an audio or MIDI file.
      SEEK_SECONDS = 5

      # Seconds Up/Down move in an audio or MIDI file.
      JUMP_SECONDS = 30

      # dB a volume key turns the monitor trim.
      VOLUME_STEP_DB = 2

      # The quietest the volume keys go (dB; one more step down mutes).
      VOLUME_FLOOR_DB = -60

      # The tempo each file starts at (a module sets its own).
      DEFAULT_BPM = 120

      # Within this many seconds of a file's start, p goes to the previous
      # file instead of back to the start.
      PREVIOUS_SECONDS = 3

      # The actions the screen's keys send (UI::Keys::PLAYER_SCREEN; a spec
      # checks the keymap binds no others).
      ACTIONS = %i[quit pause seek_back seek_forward jump_back jump_forward volume_down volume_up next_item prev_item restart].freeze

      # The files (Items), the one playing (index into #items), and its
      # state: :loading, :playing, :paused, :ended, :failed, :quit.
      attr_reader :items, :index, :state

      # The Session playing the current file.
      attr_reader :session

      # The last thing a key did (for the screen's status line and plain
      # output), and the screen (UI::Tiles) while it's up.
      attr_reader :said, :tiles

      # Actions done so far (specs wait on it).
      attr_reader :acted

      # +paths+ the files; +ui+ true (a screen on a terminal), false (plain
      # lines), or :auto (a screen when both ends are terminals); +layout+
      # a layout name for every file (default: by type); +audio+ a Proc
      # that makes each file's audio output (default: the usual one, see
      # IOMethods#output; specs give a virtual-clock NullOutput).
      def initialize(paths, ui: :auto, layout: nil, input: $stdin, output: $stdout, err: $stderr, audio: nil)
        raise ArgumentError, 'Give the player some files' if paths.nil? || paths.empty?
        @items = paths.map { |p| Item.for(p) }.freeze
        @ui = ui
        @layout = layout
        @input = input
        @output = output
        @err = err
        @audio = audio
        @index = 0
        @state = :loading
        @session = nil
        @tiles = nil
        @said = nil
        @actions = Queue.new
        @acted = 0
        @quit = false
        @started_at = nil
        @interrupts = []
      end

      # The current Item.
      def item = @items[@index]

      # True if this run draws a screen (see #initialize's +ui+).
      def screen?
        return @ui == true if @ui != :auto
        @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty? && ColorPolicy.animate?(@output)
      end

      # Seconds played of the current file (what the painter shows; reads
      # the item's position, no lock).
      def position
        s = @session or return 0.0
        item.position(s)
      rescue StandardError
        0.0
      end

      # The monitor trim in dB (-Infinity when muted).
      def volume_db
        g = Session.monitor_gain
        g > 0 ? 20 * Math.log10(g) : -Float::INFINITY
      end

      # Plays every file (until q).  Returns the number of files played.
      def run
        MB::Sound.warm_up(midi: @items.any? { |i| i.kind == :midi }) # (before the first output write; see WarmUpMethods)
        screen? ? run_screen : run_plain
      end

      # Queues an action (an Action or its name) for the player's thread
      # (the screen's keys call this).
      def act(action)
        name = action.is_a?(Symbol) ? action : action.name # (Symbol#name is its String)
        @actions << name
        nil
      end

      private

      # Plays the playlist, calling the block with each event (:start,
      # :said, :ended) for the plain output or the screen.
      def play_all
        played = 0
        until @quit || @index >= @items.length || @index < 0
          it = item
          @state = :loading
          yield :loading, it
          new_session
          unless it.load(@session.sample_rate)
            @state = :failed
            yield :failed, it
            @index += 1
            next
          end
          @state = :playing
          @started_at = MB::U.clock_now
          @session.master_gain = it.master_gain
          ending = it.start(@session)
          yield :start, it
          played += 1
          step = wait_for(ending) { |what| yield what, it }
          it.unload
          @index += step
        end
        played
      ensure
        @state = :quit
        close_session
      end

      # Waits for +ending+ while acting on the queued actions.  Returns how
      # far the playlist moves next (1, -1, 0 for again, or quits).
      def wait_for(ending)
        loop do
          while (a = (@actions.pop(true) rescue nil))
            step = do_action(a) { |what| yield what }
            @acted += 1
            return step if step
          end
          if ending.over?
            @state = ending.state == :ended ? :ended : :failed
            say(ending.reason, ending.state == :ended ? :dim : :warn) if ending.reason
            stop_now if ending.leftovers
            yield :ended
            return 1
          end
          Internal.wait_audio(@session, 0.02)
        end
      end

      # Does action +name+; returns a playlist step to end the file with,
      # or nil to keep playing.
      def do_action(name)
        s = @session
        case name
        when :quit
          @quit = true
          return 0
        when :next_item
          stop_now
          return 1
        when :prev_item
          if position > PREVIOUS_SECONDS || @index == 0
            say(item.restart)
          else
            stop_now
            return -1
          end
        when :pause
          s.paused = !s.paused?
          @state = s.paused? ? :paused : :playing
          say(s.paused? ? 'paused (Space plays on)' : 'playing')
        when :seek_back, :seek_forward
          say(item.seek_by(name == :seek_back ? -SEEK_SECONDS : SEEK_SECONDS))
        when :jump_back, :jump_forward
          say(item.jump(name == :jump_back ? -1 : 1))
        when :restart then say(item.restart)
        when :volume_up, :volume_down then say(turn_volume(name == :volume_up ? 1 : -1))
        end
        yield :said
        nil
      rescue StandardError => e
        say("#{e.class}: #{e.message}", :warn)
        yield :said
        nil
      end

      # Turns the monitor trim a step (+dir+ 1 up, -1 down); returns what to
      # say.
      def turn_volume(dir)
        db = volume_db
        if dir > 0
          return 'volume 0 dB is the top (the trim only turns down; for more, raise the system volume)' if db >= -1e-6
          db = db.finite? ? [db + VOLUME_STEP_DB, 0].min : VOLUME_FLOOR_DB
        else
          db = db.finite? && db - VOLUME_STEP_DB >= VOLUME_FLOOR_DB ? db - VOLUME_STEP_DB : -Float::INFINITY
        end
        Session.monitor_gain = db.finite? ? 10**(db / 20.0) : 0.0
        db.finite? ? format('volume %+d dB', db.round) : 'volume muted'
      end

      def say(text, role = :dim)
        @said = [text, role]
      end

      # Stops the file playing now (a 5 ms declick).
      def stop_now
        s = @session or return
        s.paused = false if s.paused?
        Session.with_context(session: s) {
          s.arrangement.playback&.stop
          MB::Sound.stop(:all, fade: PlaybackMethods::STOP_FADE)
        }
        Internal.wait_audio(s, 0.03)
      end

      # A fresh default Session for the next file (the last one's tracks,
      # tempo, and scenes don't carry over), at the start of its timeline.
      def new_session
        close_session
        MB::Sound.rewind
        MB::Sound.bpm(DEFAULT_BPM) # (a module set its tempo)
        Session.use_output(@audio.call, chosen: false) if @audio
        @session = Session.default
        @session.output # (opens it: the rate the file is read at)
        @session
      end

      def close_session
        s = @session or return
        @session = nil
        s.paused = false if s.realtime? && s.paused?
        s.close
      end

      # Plain lines (no terminal, or ui: false): a line per file, what
      # ended it, and Ctrl-C to skip (twice within a second quits).
      def run_plain
        trap_ints = Signal.trap('INT') {
          now = MB::U.clock_now
          @interrupts << now
          @interrupts.shift while @interrupts.length > 2
          @interrupts.length == 2 && now - @interrupts[0] < 1.0 ? act(:quit) : act(:next_item)
        }
        play_all do |event, it|
          case event
          when :start
            @err.puts "\e[36mPlaying\e[0m #{it.title} (#{Item.clock(it.length)}#{", #{it.info.find { |k, _| k == 'format' }&.last}" if it.kind == :module})"
          when :failed
            @err.puts "\e[33mCan't play #{it.title}: #{it.error&.message}\e[0m"
          when :ended
            @err.puts "\e[2m#{@said[0]}\e[0m" if @said && @state == :failed
          end
        end
      ensure
        Signal.trap('INT', trap_ints || 'DEFAULT')
      end

      # The screen: UI::Tiles without a console, its layout by file type.
      def run_screen
        UI.warm_up
        TerminalInfo.query!
        panes = UI.panes.merge(UI::PlayerPanes.for(self))
        on_action = ->(a) {
          if a.name == :help
            @tiles&.key_help
          elsif ACTIONS.include?(a.name)
            act(a.name)
          end
        }
        on_key = ->(k) { act(:quit) if k == :interrupt }
        @tiles = UI::Tiles.new(layout: UI.show_layouts.fetch(layout_for(item)), repl: :none, session: nil, panes: panes,
                               play_keys: UI::Keys::PLAYER_SCREEN, on_action: on_action, on_key: on_key, probe: @input.tty?,
                               input: @input, output: @output)
        UI.instance_variable_set(:@tiles, @tiles) # (UI.screen: warnings go to its messages pane)
        out = $stdout
        $stdout = UI::Messages::Writer.new(UI.messages, out)
        @tiles.start
        play_all do |event, it|
          case event
          when :loading
            @tiles.layout(UI.show_layouts.fetch(layout_for(it))) unless @tiles.layout_name == layout_for(it)
            @tiles.status_note = "loading #{it.title}"
          when :start then @tiles.status_note = nil
          when :failed then @tiles.say("can't play #{it.title}: #{it.error&.message}", :bad)
          when :said, :ended then @tiles.say(*@said) if @said
          end
        end
      ensure
        $stdout = out if out
        UI.off if @tiles
        @tiles = nil
        # (what the screen said about files it couldn't play, after it closed)
        @items.select(&:error).each { |it| @err.puts "\e[33mCouldn't play #{it.title}: #{it.error.message}\e[0m" }
      end

      # The layout for +it+: the one given, else by its kind.
      def layout_for(it)
        @layout || it.layout
      end

      # Peak levels (0..1) of +data+'s channels in +bins+ equal parts (the
      # overview of an audio file).
      def self.peaks(data, bins)
        n = data[0].length
        return Array.new(bins, 0.0) if n == 0
        per = [(n.to_f / bins).ceil, 1].max
        used = [n / per, 1].max
        peak = Numo::SFloat.zeros(used)
        data.each do |c|
          m = Numo::SFloat.cast(c[0...(used * per)]).abs.reshape(used, per).max(1)
          louder = m > peak
          peak[louder] = m[louder]
        end
        peak.to_a
      end
    end
  end
end
