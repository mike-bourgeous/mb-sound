module MB
  module Sound
    # Plays any number of graphs at once through one output, rendering them
    # all in a single loop so they stay sample-locked to one shared
    # Sequence::Transport timeline.  Used by PlaybackMethods#bg (in a
    # background thread) and PlaybackMethods#render (as fast as possible, to
    # a file).
    #
    # Graphs added while others are playing start on the next bar by default
    # (see #add).  Looping clips play in phase with the timeline, so a clip
    # shared by several graphs plays the same notes in each, whenever they
    # started.  The timeline only advances while something is playing, so it
    # pauses when the last graph stops (see Sequence::Transport#seek).
    #
    # Each graph plays under a name: a Symbol given to #add, or the lowest
    # unused Integer.  Adding a graph under a name that is already playing
    # replaces the old graph, switching over exactly at the new graph's start
    # time, so re-running the same line swaps in a new version in sync.
    #
    # Graphs with Symbol names are kept after they are stopped (see #remove),
    # so they can be brought back unchanged with #resume, e.g. to fade a
    # track out and back in.
    #
    # Blocks can be scheduled to run at a time on the timeline (see
    # #schedule and ScheduleMethods).  They run a little ahead of time on a
    # scheduler thread, and the #bg, #stop, #resume, and #bpm calls inside
    # them take effect exactly at the scheduled time.
    #
    # An error in one graph removes that graph and prints the error; other
    # graphs keep playing.
    class Session
      # A graph being played by the session.  +serial+ is unique; +name+ is
      # shared by a graph and the graph replacing it until the switch.
      #
      # +gain+ is the current fade level (0..1), changing by +gain_step+ per
      # frame.  +fade_in+ and +fade_out+ are fade lengths in bars; a player
      # with a +stop_at+ time and a +fade_out+ fades out from +stop_at+
      # instead of stopping there.  +keep+ is true if the player should be
      # kept for #resume once it stops.
      Player = Struct.new(
        :serial, :name, :input, :description, :start, :stop_at, :clip_nodes,
        :started, :slow_warned, :gain, :gain_step, :fade_in, :fade_out, :keep,
        keyword_init: true
      ) do
        # True unless this player is being replaced or stopped.
        def current?
          stop_at.nil?
        end
      end

      # A block scheduled by #schedule to run at +time+ (whole notes on the
      # timeline), repeating every +period+ whole notes if +period+ is set.
      Scheduled = Struct.new(:id, :time, :period, :block, :description, keyword_init: true)

      # Launch points for #add's +:at+ parameter (see #launch_time).
      LAUNCH_POINTS = [:now, :beat, :bar, :clip].freeze

      # The longest :clip launch wait, in bars, before falling back to :bar.
      MAX_CLIP_LAUNCH_BARS = 8

      # Default fade lengths in bars for the session used by
      # PlaybackMethods#bg (see #fade_in and #fade_out).
      DEFAULT_FADE_IN = 1/2r
      DEFAULT_FADE_OUT = 4

      # The session used by PlaybackMethods#bg, created when first needed,
      # with DEFAULT_FADE_IN and DEFAULT_FADE_OUT.
      def self.default
        @default = nil if @default&.closed?
        @default ||= new(fade_in: DEFAULT_FADE_IN, fade_out: DEFAULT_FADE_OUT)
      end

      # The playback context of the current thread, set by #with_context: a
      # Hash with the +:session+ that commands like PlaybackMethods#bg should
      # use, and while a scheduled block runs, its +:time+ and a +:batch+
      # Array that collects the block's actions.  Nil outside any context.
      def self.context
        Thread.current[:mb_sound_session_context]
      end

      # Sets the current thread's playback context (see .context) while the
      # block runs.
      def self.with_context(**context)
        old = Thread.current[:mb_sound_session_context]
        Thread.current[:mb_sound_session_context] = context
        yield
      ensure
        Thread.current[:mb_sound_session_context] = old
      end

      # The session that commands like PlaybackMethods#bg use in the current
      # thread: the context's session, or the default session.
      def self.current
        context&.[](:session) || default
      end

      # The Sequence::Transport whose timeline this session advances.
      attr_reader :transport

      # The number of output channels.  Mono graphs play on every channel.
      attr_reader :channels

      # Bars to fade in new graphs when #add isn't given a +:fade+ (nil for
      # no fade).  Graphs replacing a named graph switch over without a
      # fade unless #add is given one.
      attr_reader :fade_in

      # Bars to fade out graphs when #remove isn't given a +:fade+ (nil to
      # stop right away).
      attr_reader :fade_out

      # Sets the default fade-in length in bars (nil, 0, or false for none).
      def fade_in=(bars)
        @fade_in = bars_or_nil(bars)
      end

      # Sets the default fade-out length in bars (nil, 0, or false for none).
      def fade_out=(bars)
        @fade_out = bars_or_nil(bars)
      end

      # Creates a session.  If +:output+ is nil, a new (unshared) output from
      # MB::Sound.output is opened when the first graph is added.
      #
      # +:realtime+ - If true, #add starts a background thread that renders
      #               continuously (writing silence while idle to keep the
      #               output fed).  If false, call #process_buffer yourself.
      # +:raise_errors+ - If true, errors in graphs are raised from
      #                   #process_buffer instead of printed.
      # +:fade_in+, +:fade_out+ - Default fade lengths in bars (see #fade_in
      #                           and #fade_out).
      def initialize(output: nil, transport: Sequence.transport, channels: 2, buffer_size: nil, realtime: true, raise_errors: false, fade_in: nil, fade_out: nil)
        self.fade_in = fade_in
        self.fade_out = fade_out
        @output = output
        @transport = transport
        @channels = channels
        @buffer_size = buffer_size
        @realtime = realtime
        @raise_errors = raise_errors

        @players = {}
        @stopped = {}
        @schedule = {}
        @next_schedule_id = 0
        @tempo_changes = []
        @taps = []
        @order = []
        @next_serial = 0
        @mutex = Mutex.new
        @thread = nil
        @closed = false
        @generation = @transport.generation
      end

      # Adds a graph to play: a GraphNode, an Array of GraphNodes (one per
      # channel), or a sound filename.  Returns the player's name for #remove:
      # +:name+ if given, or else the lowest unused Integer.
      #
      # If a graph is already playing under +:name+, it keeps playing until
      # the new graph starts, then stops on that exact sample, or crossfades
      # over +:fade+ bars if given.
      #
      # +:fade+ also fades the new graph in over that many bars.  If not
      # given, new graphs fade in over #fade_in bars, and replacements switch
      # without a fade.  Pass 0 or false for no fade.
      #
      # +:at+ sets when the graph starts on the timeline: :now, :beat (next
      # quarter note), :bar (next bar), :clip (next time every looping clip
      # in the graph is back at its start), or a note length grid (an Integer
      # note division or Rational whole notes, e.g. 2r for every two bars).
      # Defaults to :now if nothing else is playing, :bar otherwise.
      # +:start_time+ instead gives an exact timeline position in whole notes
      # (used for scheduled actions).
      def add(sound, at: nil, name: nil, fade: nil, description: nil, start_time: nil)
        raise IOError, 'Session is closed' if @closed
        raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol) || name.is_a?(Integer)
        explicit_fade = !fade.nil?
        fade = bars_or_nil(fade)

        nodes = to_nodes(sound)
        input = MB::Sound::GraphNodeInput.new(nodes)
        clip_nodes = nodes.flat_map { |n| [n, *n.graph] }.grep(Sequence::ClipNode).uniq

        name = @mutex.synchronize {
          name ||= (1..).find { |i| !names_in_use.include?(i) }
          start = start_time ? start_time.to_r : launch_time(at, clip_nodes)
          @stopped.delete(name)

          replacing = @players.each_value.any? { |p| p.name == name && p.current? && p.started }
          fade = @fade_in unless explicit_fade || replacing

          # Hand over from the graph being replaced at the new start time
          @players.each_value do |p|
            next unless p.name == name && p.current?
            if p.started
              p.stop_at = start
              p.fade_out = fade
            else
              @players.delete(p.serial)
            end
          end

          start_player(
            name: name,
            input: input,
            description: shorten(description || MB::Sound.send(:playback_info, sound).to_s),
            clip_nodes: clip_nodes,
            start: start,
            fade: fade
          )
        }

        if @realtime
          output # open here so output errors are raised to the caller
          start_thread
        end
        name
      end

      # Removes the players with the given names (all players if no names are
      # given), including graphs they were replacing.  Players that have
      # started fade out over +:fade+ bars first (#fade_out bars if not given;
      # 0 or false to stop right away).  Returns the names that were removed.
      #
      # Players with Symbol names are kept once they stop, for #resume.
      #
      # +:time+ stops (or starts fading) at that timeline position in whole
      # notes instead of now (used for scheduled actions).
      def remove(*names, fade: nil, time: nil)
        fade = fade.nil? ? @fade_out : bars_or_nil(fade)
        time = time&.to_r
        time = nil if time && time <= @transport.position

        @mutex.synchronize {
          names = names_in_use if names.empty?
          removed = names.select { |n|
            matches = @players.values.select { |p| p.name == n }
            matches.each do |p|
              p.keep = true if p.current? && p.name.is_a?(Symbol)

              if time
                if !p.started && p.start >= time
                  # It would never have played
                  @players.delete(p.serial)
                  keep_stopped(p)
                else
                  p.stop_at = MB::M.min(p.stop_at || time, time)
                  p.fade_out = fade
                end
              elsif fade && p.started
                # Fade from wherever the player is now, even if it was already
                # being replaced or faded
                p.stop_at = MB::M.min(p.stop_at || @transport.position, @transport.position)
                p.fade_out = fade
                p.gain_step = 0 if p.gain_step > 0
              else
                @players.delete(p.serial)
                keep_stopped(p)
              end
            end
            matches.any?
          }
          @order -= removed
          removed
        }
      end

      # Plays a stopped graph again (see #remove), with the same launch and
      # fade options as #add.  With no +name+, resumes the most recently
      # stopped graph.  Returns the name, or nil if there is nothing to
      # resume under that name (or it is already playing).
      #
      # Looping clips come back in phase with the timeline.  Other nodes
      # keep their state from when they stopped, so e.g. a delay or reverb
      # may replay the start of an old tail.
      def resume(name = nil, at: nil, fade: nil, start_time: nil)
        fade = fade.nil? ? @fade_in : bars_or_nil(fade)

        name = @mutex.synchronize {
          name ||= @stopped.keys.last
          p = @stopped[name]
          next nil if p.nil? || @players.each_value.any? { |o| o.name == name && o.current? }

          @stopped.delete(name)
          start_player(
            name: name,
            input: p.input,
            description: p.description,
            clip_nodes: p.clip_nodes,
            start: start_time ? start_time.to_r : launch_time(at, p.clip_nodes),
            fade: fade
          )
        }

        if name && @realtime
          output
          start_thread
        end
        name
      end

      # Returns a Hash from name to description of stopped graphs that can be
      # resumed (see #resume), most recently stopped last.
      def stopped
        @mutex.synchronize { @stopped.transform_values(&:description) }
      end

      # Discards the named stopped graphs (all of them if no names are
      # given), so they can no longer be resumed.  Returns the names that
      # were discarded.
      def forget(*names)
        @mutex.synchronize {
          names = @stopped.keys if names.empty?
          names.select { |n| @stopped.delete(n) }
        }
      end

      # Removes the most recently added player that is still playing (see
      # #remove for +:fade+).  Returns its name, or nil if nothing is playing.
      def remove_last(fade: nil, time: nil)
        name = @mutex.synchronize { @order.last }
        name && remove(name, fade: fade, time: time).first
      end

      # Changes the tempo to +bpm+ when the timeline reaches +time+ (whole
      # notes), at the start of the buffer that contains it.
      def change_tempo(bpm, time:)
        raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
        @mutex.synchronize { @tempo_changes << [time.to_r, bpm] }
        bpm
      end

      # Schedules the block to run at +time+ (whole notes on the timeline),
      # and then every +period+ whole notes if given.  Returns an id for
      # #cancel.
      #
      # Blocks run a little ahead of their time (on a scheduler thread for a
      # realtime session), inside a context (see .with_context) where the
      # #bg, #stop, #resume, and #bpm commands take effect exactly at the
      # scheduled time.  If a block takes so long that its time has already
      # passed, its commands are skipped with a warning.
      #
      # Schedules follow the timeline, which only moves while something is
      # playing.  A block whose time has already come runs as soon as
      # possible.
      def schedule(time, period: nil, description: nil, &block)
        raise ArgumentError, 'Pass a block to schedule' unless block
        raise ArgumentError, "Period must be positive (got #{period.inspect})" if period && period <= 0

        @mutex.synchronize {
          @next_schedule_id += 1
          @schedule[@next_schedule_id] = Scheduled.new(
            id: @next_schedule_id,
            time: time.to_r,
            period: period&.to_r,
            block: block,
            description: description || "bar #{bar_of(time.to_r)}"
          )
          @next_schedule_id
        }
      end

      # Removes scheduled blocks (all of them if no ids are given).  Returns
      # the ids that were removed.
      def cancel(*ids)
        @mutex.synchronize {
          ids = @schedule.keys if ids.empty?
          ids.select { |id| @schedule.delete(id) }
        }
      end

      # Returns a Hash from schedule id to a description of when it runs.
      def scheduled
        @mutex.synchronize { @schedule.transform_values(&:description) }
      end

      # Returns true if a scheduled block's time has come (so it will run on
      # the next buffer even if nothing is playing).
      def schedule_due?
        @mutex.synchronize { @schedule.each_value.any? { |e| e.time <= @transport.position } }
      end

      # Returns a Hash from player name to a description, noting players
      # that are waiting for their start time or fading out.
      def players
        @mutex.synchronize {
          @players.values.sort_by { |p| p.current? ? 1 : 0 }.to_h { |p|
            status = if !p.current? && p.stop_at > @transport.position
                       " (stops at bar #{bar_of(p.stop_at)})"
                     elsif !p.current?
                       ' (fading out)'
                     elsif !p.started
                       " (starts at bar #{bar_of(p.start)})"
                     end
            [p.name, "#{p.description}#{status}"]
          }
        }
      end

      # Calls the block with every buffer of the mix (an Array of
      # Numo::SFloat, one per channel) after it is written to the output,
      # e.g. for plotting.  The arrays are new for each buffer, so the block
      # may keep them.  The block runs on the rendering thread, so it must
      # return quickly.  Returns the block, for #remove_tap.
      def add_tap(&block)
        raise ArgumentError, 'Pass a block to tap the mix' unless block
        @mutex.synchronize { @taps << block }
        block
      end

      # Stops calling a block given to #add_tap.
      def remove_tap(block)
        @mutex.synchronize { @taps.delete(block) }
      end

      # Returns true if the background rendering thread is running (see
      # #add).
      def running?
        !!@thread&.alive?
      end

      # Returns true if no players are playing or waiting to start.
      def idle?
        @mutex.synchronize { @players.empty? }
      end

      # The output being written, opening it if needed.
      def output
        @output ||= MB::Sound.output(channels: @channels, shared: false)
      end

      # The number of frames rendered per #process_buffer.
      def buffer_size
        @buffer_size || output.buffer_size
      end

      # Renders +count+ frames from every player, mixes them, writes the mix
      # to the output, and advances the timeline (unless idle).  Returns the
      # mix (an Array of Numo::SFloat, one per channel).
      def process_buffer(count = buffer_size)
        apply_tempo_changes

        per_sample = @transport.whole_notes_per_second / output.sample_rate.to_r
        from = @transport.position
        to = from + count * per_sample

        # If the timeline was seeked, move every running graph's clips there,
        # and move repeating schedules to their next time
        if @generation != @transport.generation
          @generation = @transport.generation
          @mutex.synchronize { @players.values }.each do |p|
            p.clip_nodes.each { |n| n.start_at(from, origin: p.start, transport: @transport) } if p.started
          end
          @mutex.synchronize {
            @schedule.each_value do |e|
              e.time = from + (e.time - from) % e.period if e.period
            end
          }
        end

        dispatch_schedule(from, to)

        players = @mutex.synchronize { @players.values }

        mix = Array.new(@channels) { Numo::SFloat.zeros(count) }
        players.each do |p|
          render_player(p, mix, from, to, per_sample, count)
        end

        @transport.advance(to - from) unless players.empty?
        output.write(mix)
        call_taps(mix)
        mix
      end

      # Stops the background and scheduler threads and closes the output.
      def close
        return if @closed
        @closed = true
        @thread&.join(5)
        @schedule_queue&.close
        @scheduler&.join(5)
        @output&.close
      end

      # Returns true if #close was called.
      def closed?
        @closed
      end

      private

      # Applies tempo changes from #change_tempo whose time has come.
      def apply_tempo_changes
        due = @mutex.synchronize {
          now, @tempo_changes = @tempo_changes.partition { |time, _| time <= @transport.position }
          now
        }
        due.sort_by(&:first).each { |_, bpm| @transport.bpm = bpm }
      end

      # Starts scheduled blocks whose time is before +to+ plus half a bar of
      # lookahead while playing, or whose time has come while idle.
      def dispatch_schedule(from, to)
        playing = !idle?
        horizon = playing ? to + @transport.bar_length / 2 : from

        due = @mutex.synchronize {
          list = []
          @schedule.values.each do |e|
            while e.time <= horizon
              list << [e, e.time]
              break @schedule.delete(e.id) unless e.period
              e.time += e.period
            end
          end
          list
        }

        due.sort_by(&:last).each do |e, time|
          # Blocks for times still ahead must finish in time; blocks whose
          # time has already come run as soon as possible
          deadline = time > from ? time : nil
          if @realtime
            start_scheduler
            @schedule_queue << [e, time, deadline]
          else
            run_scheduled(e, time, deadline)
          end
        end
      end

      # Runs a scheduled block, collecting its commands and then applying
      # them if the block finished before +deadline+ (see #schedule).
      def run_scheduled(entry, time, deadline)
        batch = []
        Session.with_context(session: self, time: time, batch: batch) do
          entry.block.call
        end

        if deadline && @transport.position >= deadline
          warn "Skipped the commands scheduled for #{entry.description}: the block finished after its time"
        else
          batch.each(&:call)
        end

      rescue => e
        raise if @raise_errors
        warn "Scheduled block for #{entry.description} raised #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
      end

      # Starts the thread that runs scheduled blocks for a realtime session.
      def start_scheduler
        return if @scheduler&.alive?

        @schedule_queue ||= Queue.new
        @scheduler = Thread.new do
          while (item = @schedule_queue.pop)
            run_scheduled(*item)
          end
        end
        @scheduler.name = 'MB::Sound::Session scheduler'
      end

      # Shortens a graph description for #players.
      def shorten(text, max = 60)
        text.length > max ? "#{text[0, max - 3]}..." : text
      end

      # Converts a fade length to a positive Rational number of bars, or nil
      # for no fade (nil, false, or 0).
      def bars_or_nil(bars)
        return nil if bars.nil? || bars == false || bars == 0
        raise ArgumentError, "Fade must be a positive number of bars (got #{bars.inspect})" unless bars.is_a?(Numeric) && bars.finite? && bars > 0
        bars.is_a?(Float) ? bars.rationalize(Rational(1, 10_000)) : bars.to_r
      end

      # The gain change per frame for a fade lasting +bars+ at the current
      # tempo.
      def fade_step(bars, rate)
        1.0 / (@transport.seconds(bars * @transport.bar_length) * rate)
      end

      # Creates and registers a Player.  Called with @mutex held.  Returns
      # the name.
      def start_player(name:, input:, description:, clip_nodes:, start:, fade:)
        @next_serial += 1
        @players[@next_serial] = Player.new(
          serial: @next_serial,
          name: name,
          input: input,
          description: description,
          start: start,
          clip_nodes: clip_nodes,
          started: false,
          slow_warned: false,
          gain: fade ? 0.0 : 1.0,
          gain_step: 0.0,
          fade_in: fade,
          keep: false
        )

        @order.delete(name)
        @order << name
        name
      end

      # Keeps a stopped player for #resume if it was marked to be kept.
      # Called with @mutex held.
      def keep_stopped(p)
        return unless p.keep
        @stopped.delete(p.name)
        @stopped[p.name] = p
      end

      # Names of players that are playing, waiting to start, or fading out.
      # Called with @mutex held.
      def names_in_use
        @players.each_value.map(&:name).uniq
      end

      # Removes one player by serial number, e.g. when it ends.  If +keep+ is
      # true and the player was stopped with #remove, it is kept for #resume.
      def retire(p, keep: false)
        @mutex.synchronize {
          @players.delete(p.serial)
          keep_stopped(p) if keep
          @order.delete(p.name) unless @players.each_value.any? { |o| o.name == p.name }
        }
      end

      # Converts something playable into an Array of GraphNodes.
      def to_nodes(sound)
        case sound
        when String
          [MB::Sound.file_input(sound)]
        when MB::Sound::GraphNode
          [sound]
        when Array
          raise ArgumentError, 'Pass an Array of GraphNodes, one per channel' unless !sound.empty? && sound.all?(MB::Sound::GraphNode)
          sound
        else
          raise ArgumentError, "Cannot play #{sound.class} in the background; use a GraphNode, an Array of GraphNodes, or a filename"
        end
      end

      # Returns the timeline position where a new graph should start.  See
      # #add.  Called with @mutex held.
      def launch_time(at, clip_nodes)
        at ||= @players.empty? ? :now : :bar

        grid = case at
               when :now
                 return @transport.position
               when :beat
                 1/4r
               when :bar
                 @transport.bar_length
               when :clip
                 clip_grid(clip_nodes)
               when Symbol
                 raise ArgumentError, "Unknown launch point #{at.inspect} (use #{LAUNCH_POINTS.map(&:inspect).join(', ')}, or a note length)"
               else
                 Sequence::Duration.whole_notes(at)
               end

        @transport.next_boundary(grid)
      end

      # The time between moments when every looping clip is at its start
      # (the least common multiple of their lengths), or a bar if that is
      # too long or there are no looping clips.
      def clip_grid(clip_nodes)
        lengths = clip_nodes.map(&:clip).select(&:looping?).map(&:length).uniq
        return @transport.bar_length if lengths.empty?

        lcm = lengths.reduce { |a, b| Rational(a.numerator.lcm(b.numerator), a.denominator.gcd(b.denominator)) }
        if lcm > @transport.bar_length * MAX_CLIP_LAUNCH_BARS
          warn "Clips only line up every #{(lcm / @transport.bar_length).round(2)} bars; starting on the next bar instead"
          return @transport.bar_length
        end

        lcm
      end

      # Renders one player into +mix+, starting it partway through the buffer
      # if its launch time falls there, stopping it partway through if it is
      # being replaced, and removing it when it ends or raises an error.
      def render_player(p, mix, from, to, per_sample, count)
        return if p.start >= to

        rate = output.sample_rate.to_f
        if p.stop_at && p.stop_at <= from
          return retire(p, keep: p.keep) unless p.fade_out
          p.gain_step = -fade_step(p.fade_out, rate) if p.gain_step >= 0
        end

        offset = 0
        unless p.started
          offset = MB::M.max(((p.start - from) / per_sample).ceil, 0)
          start = from + offset * per_sample
          p.clip_nodes.each { |n| n.start_at(start, origin: start, transport: @transport) }
          p.start = start
          p.started = true
          p.gain_step = fade_step(p.fade_in, rate) if p.fade_in
        end

        frames = count - offset
        frames = MB::M.min(frames, ((p.stop_at - from) / per_sample).ceil - offset) if p.stop_at && !p.fade_out
        t = MB::U.clock_now
        data = p.input.read(frames)
        check_speed(p, MB::U.clock_now - t, frames)

        if data.nil? || data.empty? || data.all? { |d| d.nil? || d.empty? }
          retire(p)
          return
        end

        ramp = fade_ramp(p, frames)

        mix.each_with_index do |m, c|
          d = data[c % data.length]
          next if d.nil? || d.empty?
          d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
          len = MB::M.min(d.length, frames)
          d = d[0...len]
          d = d * ramp[0...len] if ramp
          m[offset...(offset + len)] = m[offset...(offset + len)] + d
        end

        # A short read means the graph ended; a replaced graph ends at its
        # replacement's start unless it is fading; a fade out ends at silence
        ended = data.any? { |d| d.nil? || d.length < frames }
        cut = p.stop_at && p.stop_at < to && !p.fade_out
        faded = p.gain <= 0 && p.gain_step < 0
        if ended
          retire(p)
        elsif cut
          retire(p, keep: p.keep)
        elsif faded
          retire(p, keep: true)
        end

      rescue => e
        retire(p)
        raise if @raise_errors
        warn "Player #{p.name.inspect} (#{p.description}) stopped with an error: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
      end

      # Calls each #add_tap block with the mix, removing blocks that raise.
      def call_taps(mix)
        taps = @mutex.synchronize { @taps.dup }
        taps.each do |t|
          t.call(mix)
        rescue => e
          remove_tap(t)
          warn "Removed a mix tap that raised #{e.class}: #{e.message}"
        end
      end

      # Returns a Numo::SFloat of per-frame gains for a fading player (and
      # advances its fade), or nil if the player is at full volume.
      def fade_ramp(p, frames)
        return nil if p.gain >= 1 && p.gain_step >= 0

        ramp = Numo::SFloat.new(frames).seq(p.gain, p.gain_step).clip(0, 1)
        p.gain = MB::M.clamp(p.gain + p.gain_step * frames, 0.0, 1.0)
        p.gain_step = 0.0 if p.gain >= 1 && p.gain_step > 0
        ramp
      end

      # Warns once if a player takes most of the time available for its
      # buffer, which means it will soon cause dropouts for every player.
      def check_speed(p, elapsed, frames)
        return unless @realtime && !p.slow_warned

        budget = frames.to_f / output.sample_rate
        if elapsed > 0.75 * budget
          p.slow_warned = true
          warn "Player #{p.name.inspect} (#{p.description}) took #{(100 * elapsed / budget).round}% of its audio buffer time; it may cause dropouts"
        end
      end

      # Starts the background rendering thread if it isn't running.
      def start_thread
        return if @thread&.alive?

        @thread = Thread.new do
          until @closed
            process_buffer
          end
        rescue => e
          warn "Background session stopped with an error: #{e.class}: #{e.message}"
        end
        @thread.name = 'MB::Sound::Session'

        # Stop the thread and close the output cleanly at exit
        unless @at_exit_registered
          at_exit { close rescue nil }
          @at_exit_registered = true
        end
      end

      # The bar number (counting from 1) of a timeline position.
      def bar_of(position)
        (position / @transport.bar_length).floor + 1
      end
    end
  end
end
