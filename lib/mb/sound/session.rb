require 'monitor'

require_relative 'launch_point'

require_relative 'session/journal'
require_relative 'session/names'
require_relative 'session/changes'
require_relative 'session/fades'
require_relative 'session/strip'
require_relative 'session/undo'
require_relative 'session/master'
require_relative 'session/tails'
require_relative 'session/markers'
require_relative 'session/seeks'
require_relative 'session/clip_swaps'
require_relative 'session/scheduler'
require_relative 'session/graph_view'
require_relative 'session/knobs'
require_relative 'session/midi_in'
require_relative 'session/audio_recording'
require_relative 'session/stems'

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
    #
    # The mix of every graph can run through master effects (see #master)
    # before it reaches the output.  The clips a graph plays can be changed
    # without replacing the graph (see #swap).
    class Session
      include Changes
      include Fades
      include Strip
      include Undo
      include Master
      include Tails
      include ClipSwaps
      include Seeks
      include GraphView
      include Knobs
      include MidiIn
      include AudioRecording
      include Stems

      # A graph being played by the session.  +serial+ is unique; +name+ is
      # shared by a graph and the graph replacing it until the switch.
      #
      # +gain+ is the current fade level (0..1) while +ramp+ (a Fades::Ramp)
      # is nil; +ramp+ is a fade in progress.  +fade_in+ and +fade_out+ are
      # fade lengths in bars; a player with a +stop_at+ time and a
      # +fade_out+ fades out from +stop_at+ (+fading_out+ once it has
      # begun) instead of stopping there.  +keep+ is true if the player
      # should be kept for #resume once it stops.  +start+ becomes the start
      # of the sample the player starts on; +launch+ stays the exact launch
      # time (see Sequence::TimelineNode#start_at).
      #
      # +strip_level+ and +strip_ramp+ are the mute/solo level (see Strip);
      # +asleep+ is true while a muted player isn't being rendered.
      #
      # +ring+ is a Tails::Ring while the player rings out after a stop
      # (see Tails).
      Player = Struct.new(
        :serial, :name, :input, :description, :start, :launch, :stop_at, :timeline_nodes,
        :started, :slow_warned, :loads, :gain, :ramp, :fade_in, :fade_out, :fading_out, :keep,
        :strip_level, :strip_ramp, :asleep, :ring,
        keyword_init: true
      ) do
        # True unless this player is being replaced or stopped.
        def current?
          stop_at.nil?
        end
      end

      # Launch point alignments for +:on+ (see LaunchPoint).
      LAUNCH_POINTS = LaunchPoint::ALIGNMENTS

      # The longest :clip launch wait, in bars, before falling back to :bar.
      MAX_CLIP_LAUNCH_BARS = 8

      # Default fade lengths in bars for the session used by
      # PlaybackMethods#bg (see #fade_in and #fade_out).
      DEFAULT_FADE_IN = 1/2r
      DEFAULT_FADE_OUT = 4

      # The session used by PlaybackMethods#bg, created when first needed,
      # with DEFAULT_FADE_IN and DEFAULT_FADE_OUT.
      def self.default
        if @default&.closed?
          @default = nil
          @output_chosen = false
        end
        @default ||= new(fade_in: DEFAULT_FADE_IN, fade_out: DEFAULT_FADE_OUT)
      end

      # True if the default session's output was chosen by the user (given
      # to .use_output with +chosen: true+, e.g. through
      # PlaybackMethods#use_output or #latency), rather than opened
      # automatically.  Live MIDI's automatic switch to the :low latency
      # profile leaves a chosen output alone (see
      # PlaybackMethods#live_midi_latency).
      def self.output_chosen?
        !!@output_chosen && !@default.nil? && !@default.closed?
      end

      # Replaces the default session (see .default) with a new one that
      # plays through +output+ (any object with the output interface, e.g.
      # an FFMPEGOutput streaming to a URL; closed with the session), or with
      # nil to open the usual output from MB::Sound.output when next needed.
      # Raises if the current default session still has players, since its
      # graphs and master effects aren't moved to the new session.  See
      # PlaybackMethods#use_output.  Pass +chosen: false+ when the output
      # wasn't the user's choice (see .output_chosen?).
      def self.use_output(output, chosen: true)
        if @default && !@default.closed?
          raise ArgumentError, 'Stop the background players first (e.g. panic)' unless @default.idle?
          @default.close
        end

        @output_chosen = !output.nil? && chosen
        @default = output && new(output: output, fade_in: DEFAULT_FADE_IN, fade_out: DEFAULT_FADE_OUT)
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

      # The session #current would return, without creating the default
      # session: nil if there is none (or it is closed).
      def self.existing
        context&.[](:session) || (@default unless @default&.closed?)
      end

      # The performance context of the current thread, set by
      # #with_perform while a take replays (see Take): a Hash with the
      # +:session+, the +:forced+ landing times of the line's changes, the
      # logical +:now+ (the line's recorded issue time), the +:source+ of
      # changes, and the take +:line+ id.  Nil outside a replay or undo.
      def self.perform
        Thread.current[:mb_sound_session_perform]
      end

      # Merges +settings+ into the current thread's performance context
      # (see .perform) while the block runs.
      def self.with_perform(**settings)
        old = Thread.current[:mb_sound_session_perform]
        Thread.current[:mb_sound_session_perform] = (old || {}).merge(settings)
        yield
      ensure
        Thread.current[:mb_sound_session_perform] = old
      end

      # Adds a change to the undoable command running on this thread, if
      # any (see Undo#command).  Called by Changes#change.
      def self.note_command_change(session, change)
        group = Thread.current[:mb_sound_command]
        group[:changes] << change if group && group[:session].equal?(session)
      end

      # The Sequence::Transport whose timeline this session advances.
      attr_reader :transport

      # The Tuning for notes played in this session (MB::Sound.tuning).
      attr_reader :tuning

      # The default master bus gain (-10 dB), leaving headroom for mixes of
      # full-scale oscillators.
      DEFAULT_MASTER_GAIN = 10 ** (-10 / 20.0)

      # The linear gain applied to the whole mix after master effects, before
      # it's written to the output (and seen by taps).  See
      # PlaybackMethods#master_gain.
      attr_reader :master_gain

      # Sets the master bus gain (linear; e.g. `-6.db`).
      def master_gain=(gain)
        raise ArgumentError, "Master gain must be a Numeric (got #{gain.inspect})" unless gain.is_a?(Numeric)
        @master_gain = gain.to_f
      end

      # The number of output channels.  Mono graphs play on every channel.
      attr_reader :channels

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
      def initialize(output: nil, transport: Sequence.transport, tuning: Tuning.default, master_gain: DEFAULT_MASTER_GAIN, channels: 2, buffer_size: nil, realtime: true, raise_errors: false, fade_in: nil, fade_out: nil)
        @transport = transport
        @tuning = tuning
        self.master_gain = master_gain
        self.fade_in = fade_in
        self.fade_out = fade_out
        @output = output
        @channels = channels
        @buffer_size = buffer_size
        @realtime = realtime
        @raise_errors = raise_errors

        @players = {}
        @stopped = {}
        @taps = []
        @master_chains = []
        @order = []
        @next_serial = 0
        @mutex = Mutex.new
        @thread = nil
        @closed = false
        @generation = @transport.generation
        @scheduler = Scheduler.new(self, realtime: realtime, raise_errors: raise_errors)

        init_changes
        init_strip
        init_undo
        init_knobs
        init_midi_in
        init_audio_recording
        @names = Names.new
        @arrangement = nil
      end

      # The Session's top-level names (see Names).
      attr_reader :names

      # The marker table (see Markers), created when first needed.
      def markers
        @markers ||= Markers.new(self)
      end

      # The Set layer of this Session (tracks and scenes; see
      # MB::Sound::Arrangement), created when first needed.
      def arrangement
        @arrangement ||= Arrangement.new(self)
      end

      # True if a player named +name+ will be playing once the changes
      # waiting in the change queue have landed.
      def playing_after_queue?(name)
        @render_lock.synchronize {
          playing = @mutex.synchronize { @players.each_value.any? { |p| p.name == name && p.current? } }
          @changes.each do |c|
            next unless c.subject == name
            playing = true if START_KINDS.include?(c.kind) && c.kind != :restore
            playing = false if c.kind == :stop
          end
          playing
        }
      end

      # The Sequence::TimelineNodes in +sound+ (a graph, an Array of them,
      # or a bundle), as #add finds them.
      def timeline_nodes_in(sound)
        to_nodes(sound).flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq
      end

      # The timeline nodes of the player named +name+ (playing, stopped, or
      # waiting in the change queue), or an empty Array.
      def timeline_nodes_of(name)
        @render_lock.synchronize {
          p = @mutex.synchronize { @players.values.select { |o| o.name == name && o.current? }.last || @stopped[name] }
          p&.timeline_nodes || @changes.select { |c| c.subject == name && c.starts }.last&.starts || []
        }
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
      # +:on+, +:in+, and +:at+ set when the graph starts on the timeline
      # (see LaunchPoint): +on:+ aligns to :now, :beat (next quarter note),
      # :bar (next bar), :clip (next time every looping clip in the graph is
      # back at its start; launch-aligned loops, which start at their
      # beginning anyway, don't count), a number of bars, or a note length
      # grid (e.g. 1.n4); +in:+ is an offset from now and +at:+ an absolute
      # position (e.g. bar(9)).  Defaults to on: :now if nothing else is
      # playing, :bar otherwise.  +:start_time+ instead gives an exact
      # timeline position in whole notes (used for scheduled actions).
      # Inside a scheduled block, launch points count from the block's time
      # (see Changes#now).
      #
      # The graph is built and prepared right away; the change goes through
      # the change queue (see Changes), so it lands exactly at its time even
      # if other changes for the same name are waiting.
      def add(sound, at: nil, on: nil, in: nil, name: nil, fade: nil, description: nil, start_time: nil)
        raise IOError, 'Session is closed' if @closed
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol) || name.is_a?(Integer)
        explicit_fade = !fade.nil?
        fade = bars_or_nil(fade)

        nodes = match_rate(to_nodes(sound))
        adopt_knobs(nodes) # graph documents' knobs join the Session (see Knobs#adopt_knobs)
        input = MB::Sound::GraphNodeInput.new(nodes)
        Plan.install(nodes) # fused plans (see MB::Sound::Plan), after the input's branches
        timeline_nodes = nodes.flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq
        description = shorten(description || MB::Sound.send(:playback_info, sound).to_s)

        time = start_time ? start_time.to_r : launch_time(point, timeline_nodes)

        @render_lock.synchronize {
          name = @mutex.synchronize {
            name ||= (1..).find { |i| !names_in_use.include?(i) }
            @order.delete(name)
            @order << name
            name
          }

          change(:bg, name, time, data: { description: description, fade: fade }, starts: timeline_nodes) { |t|
            add_now(name: name, input: input, description: description, timeline_nodes: timeline_nodes, start: t, fade: fade, explicit_fade: explicit_fade)
          }
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
      # notes instead of now (used for scheduled actions).  A stop for now
      # also cancels graphs waiting in the change queue to start under those
      # names.
      #
      # +ring: true+ rings players out instead (see Tails): their clips stop
      # sending notes at the stop time and the graph keeps playing until it
      # is silent (+fade+ is then ignored; graphs without clips fade out
      # over Tails::RING_DRONE_FADE bars).
      def remove(*names, fade: nil, time: nil, ring: false)
        fade = ring ? nil : (fade.nil? ? @fade_out : bars_or_nil(fade))
        time = time&.to_r
        time = nil if time && time <= @transport.position

        @render_lock.synchronize {
          names = @mutex.synchronize { names_in_use } if names.empty?
          removed = names.select { |n|
            playing = @mutex.synchronize { @players.each_value.any? { |p| p.name == n } }
            waiting = @changes.select { |c| c.subject == n && START_KINDS.include?(c.kind) }

            # A stop for now cancels starts that haven't happened yet
            cancel_changes(*waiting) if time.nil?

            if playing || (time && !waiting.empty?)
              data = ring ? { ring: true } : { fade: fade }
              change(:stop, n, time, data: data) { |t| remove_now(n, fade: fade, time: t, ring: ring) }
            end

            playing || !waiting.empty?
          }

          @mutex.synchronize { @order -= removed }
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
      def resume(name = nil, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
        point = LaunchPoint.of(binding) or return nil
        fade = fade.nil? ? @fade_in : bars_or_nil(fade)

        @render_lock.synchronize {
          p = @mutex.synchronize {
            name ||= @stopped.keys.last
            p = @stopped[name] || ringing_player(name)
            next nil if p.nil? || @players.each_value.any? { |o| o.name == name && o.current? }
            p
          }
          next nil if p.nil? || @changes.any? { |c| c.subject == name && START_KINDS.include?(c.kind) }

          time = start_time ? start_time.to_r : launch_time(point, p.timeline_nodes)
          change(:resume, name, time, data: { fade: fade }, starts: p.timeline_nodes) { |t| resume_now(name, start: t, fade: fade) }
          @mutex.synchronize { @order.delete(name); @order << name }
          name
        }.tap { |resumed|
          if resumed && @realtime
            output
            start_thread
          end
        }
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
      def remove_last(fade: nil, time: nil, ring: false)
        name = @render_lock.synchronize { @mutex.synchronize { @order.last } }
        name && remove(name, fade: fade, time: time, ring: ring).first
      end

      # Changes the tempo to +bpm+ when the timeline reaches +time+ (whole
      # notes), at the start of the buffer that contains it.
      def change_tempo(bpm, time:)
        @scheduler.change_tempo(bpm, time: time)
      end

      # Runs the block when the timeline reaches +time+ (whole notes), at the
      # start of the buffer that contains it, on the render thread (so keep
      # it short).  Used for live changes from scheduled blocks, like
      # TuningMethods#tuning.
      def at_time(time, &action)
        @scheduler.at_time(time, &action)
      end

      # Schedules the block to run at +time+ (whole notes on the timeline),
      # and then every +period+ whole notes if given.  Returns an id for
      # #cancel.  See Scheduler for how and when blocks run.
      def schedule(time, period: nil, description: nil, epoch: nil, &block)
        @scheduler.schedule(time, period: period, description: description, epoch: epoch, &block)
      end

      # Starts the background rendering thread of a realtime session (and
      # opens its output) if it isn't running, so scheduled blocks run even
      # before anything plays (e.g. a song form's first section).
      def ensure_running
        return unless @realtime && !@closed
        output
        start_thread
      end

      # Removes scheduled blocks (all of them if no ids are given).  Returns
      # the ids that were removed.
      def cancel(*ids)
        @scheduler.cancel(*ids)
      end

      # Returns a Hash from schedule id to a description of when it runs.
      def scheduled
        @scheduler.scheduled
      end

      # Returns true if a scheduled block's time has come (so it will run on
      # the next buffer even if nothing is playing).
      def schedule_due?
        @scheduler.due?
      end

      # How far ahead of their time scheduled blocks (song form sections,
      # at_bar blocks) run in a realtime session, so graphs they build are
      # ready when their changes land: :auto (the default; half a bar, more
      # after slow blocks, up to 2 bars) or a number of bars.  See
      # Scheduler#lookahead.
      def lookahead
        @scheduler.lookahead
      end

      # Sets #lookahead (:auto or a number of bars).
      def lookahead=(value)
        @scheduler.lookahead = value
      end

      # The lookahead used now, in bars (see #lookahead).
      def lookahead_bars
        (@scheduler.lookahead_whole_notes / @transport.bar_length).to_r
      end

      # Scheduled blocks that finished after their time, newest last (see
      # Scheduler#late).
      def late_blocks
        @scheduler.late
      end

      # Returns a Hash from player name to a description, noting players
      # that are waiting for their start time, stopping, or fading out.  If a
      # name has both a current player and one being replaced, the current
      # player is shown.
      #
      # Graphs waiting in the change queue to start are listed too, and
      # queued stops are noted.
      def players
        @render_lock.synchronize {
          list = @mutex.synchronize {
            @players.values.group_by(&:name).transform_values { |list|
              p = list.find(&:current?) || list.first
              status = if !p.current? && p.stop_at > @transport.position
                         " (stops at bar #{bar_of(p.stop_at)})"
                       elsif !p.current? && p.ring&.active
                         ' (ringing out)'
                       elsif !p.current?
                         ' (fading out)'
                       elsif !p.started
                         " (starts at bar #{bar_of(p.start)})"
                       end
              status = "#{status} (muted)" if p.asleep || p.strip_level == 0 && p.strip_ramp.nil?
              "#{p.description}#{status}"
            }
          }

          @changes.each do |c|
            if START_KINDS.include?(c.kind) && !list.key?(c.subject)
              list[c.subject] = "#{c.entry.data[:description] || @stopped[c.subject]&.description || c.subject} (starts at bar #{bar_of(c.time)})"
            elsif c.kind == :stop && list.key?(c.subject) && !list[c.subject].include?('(stops')
              list[c.subject] = "#{list[c.subject]} (stops at bar #{bar_of(c.time)})"
            end
          end

          list
        }
      end

      # Changes the description #players shows for the player named +name+
      # (e.g. after a recording swapped a new clip into it).
      def describe_player(name, description)
        @mutex.synchronize {
          @players.each_value { |p| p.description = shorten(description) if p.name == name && p.current? }
        }
      end

      # How busy rendering the last buffer was: its render time (before
      # writing to the output) divided by its length in time, e.g. 0.25 when
      # rendering takes a quarter of real time.  Nil before the first buffer.
      def render_load
        @load
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

      # Returns true if no players are playing or waiting to start
      # (including graphs waiting in the change queue).
      def idle?
        @render_lock.synchronize { @mutex.synchronize { @players.empty? } && !queued_start? }
      end

      # The sample rate graphs play at: the output's (opening it if needed).
      # Graphs added at another rate are set to it (see #add).
      def sample_rate
        output.sample_rate
      end

      # The output being written, opening it if needed.
      def output
        @output ||= MB::Sound.output(channels: @channels, shared: false)
      end

      # True once the output has been given or opened (see #output).
      def output_open?
        !@output.nil?
      end

      # The number of frames rendered per #process_buffer.
      def buffer_size
        @buffer_size || output.buffer_size
      end

      # Renders +count+ frames from every player, mixes them, runs the mix
      # through the master effects (see #master), writes it to the output,
      # and advances the timeline (unless idle).  Returns the mix (an Array
      # of Numo::SFloat, one per channel).
      def process_buffer(count = buffer_size)
        started = MB::U.clock_now

        mix = @render_lock.synchronize {
          # A seek (or its undo) landing inside the buffer splits it: the
          # frames before it, then the rest from the new position (see
          # Seeks), so it lands on the same frame at any buffer size
          parts = []
          remaining = count
          while remaining > 0
            @scheduler.apply_timed_changes
            commit_due_seeks unless @changes.empty?
            per_sample = @transport.whole_notes_per_second / output.sample_rate.to_r
            n = (@changes.empty? ? nil : frames_before_seek(remaining, per_sample)) || remaining
            parts << render_span(n, per_sample)
            remaining -= n
          end
          parts.length == 1 ? parts[0] : parts.transpose.map { |chans| chans.reduce { |a, b| a.concatenate(b) } }
        }

        # How busy rendering is (before the output blocks), for deciding
        # whether master chains can crossfade
        @load = (MB::U.clock_now - started) * output.sample_rate / count

        mix = mix.map { |c| c * @master_gain } if @master_gain != 1

        output.write(mix)
        record_mix(mix, @frame - count)
        call_taps(mix)
        mix
      end

      # Renders +count+ frames (one span of #process_buffer): scheduled
      # blocks, changes landing in the span, players, and the master chain.
      # Advances the timeline and the frame counter.  Returns the mix.
      # Called with the render lock held.
      def render_span(count, per_sample)
        from = @transport.position
        to = from + count * per_sample

        # If the timeline was seeked, move every running graph's clips there,
        # and move repeating schedules to their next time
        seeked = @generation != @transport.generation
        if seeked
          @generation = @transport.generation
          @mutex.synchronize { @players.values }.each do |p|
            p.timeline_nodes.each { |n| n.start_at(from, origin: p.start, launch: p.launch, transport: @transport) } if p.started
          end
          @scheduler.seeked(from)
        end

        @scheduler.dispatch(from, to, playing: !idle?)

        # MIDI input lands on exact frames before changes (a recording
        # closing in this span needs its events) and graphs read it
        pump_midi(@frame, count, from, per_sample)

        # Changes landing in this span, after scheduled blocks (which may
        # queue some for it)
        commit_due(from, to, per_sample)

        # Knobs move before anything reads them (see Knobs)
        advance_knobs(@frame, count) unless @knobs.empty?

        players = @mutex.synchronize { @players.values }

        mix = Array.new(@channels) { Numo::SFloat.zeros(count) }
        if @stems
          render_players_with_stems(players, mix, from, to, per_sample, count, @frame)
        else
          players.each do |p|
            render_player(p, mix, from, to, per_sample, count)
          end
        end

        playing = !players.empty? || queued_start?
        @transport.advance(to - from) if playing
        mix = process_master(mix, from, to, per_sample, count, playing: playing, seeked: seeked)

        @frame += count
        @transport_record = transport_record_for(playing)
        mix
      ensure
        @knob_frame = nil
      end
      private :render_span

      # Stops the background and scheduler threads and closes the output.
      def close
        return if @closed
        @closed = true
        @thread&.join(5)
        close_recordings
        midi_inputs.each_value { |m| m.input = nil unless m.replaying? }
        @scheduler.close
        @output&.close
      end

      # Returns true if #close was called.
      def closed?
        @closed
      end

      private

      # Starts a graph built by #add at timeline position +start+, handing
      # over from the graph it replaces (applied by the change queue).
      def add_now(name:, input:, description:, timeline_nodes:, start:, fade:, explicit_fade:)
        @mutex.synchronize {
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

          start_player(name: name, input: input, description: description, timeline_nodes: timeline_nodes, start: start, fade: fade)
        }
      end

      # Stops (or starts fading out) the players named +name+ at +time+, or
      # now if +time+ is nil or has passed (applied by the change queue).
      def remove_now(name, fade:, time:, ring: false)
        time = nil if time && time <= @transport.position

        @mutex.synchronize {
          matches = @players.values.select { |p| p.name == name }
          matches.each do |p|
            p.keep = true if p.current? && p.name.is_a?(Symbol)

            # Another stop takes over from ringing out (the clips stay
            # silent until the player is retired)
            p.ring.active = false if p.ring && !ring

            if ring && p.ring
              # Already ringing out
            elsif ring && p.current? && (p.started || (time && p.start < time))
              unless start_ringing(p, time || @transport.position)
                stop = time || @transport.position
                p.stop_at = MB::M.min(p.stop_at || stop, stop)
                p.fade_out = RING_DRONE_FADE
                p.fading_out = false
              end
            elsif ring && !p.current?
              # Being replaced: it stops at its replacement's start as before
            elsif time
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
              p.fading_out = false
            else
              @players.delete(p.serial)
              keep_stopped(p)
            end
          end
          @order.delete(name) unless matches.empty?
          matches.any?
        }
      end

      # Starts a stopped player again at +start+ (applied by the change
      # queue).
      def resume_now(name, start:, fade:)
        @mutex.synchronize {
          # A player still ringing out comes back as it is (see Tails)
          next name if revive_ringing(name, start)

          p = @stopped[name]
          next nil if p.nil? || @players.each_value.any? { |o| o.name == name && o.current? }

          @stopped.delete(name)
          start_player(
            name: name,
            input: p.input,
            description: p.description,
            timeline_nodes: p.timeline_nodes,
            start: start,
            fade: fade
          )
        }
      end

      # Shortens a graph description for #players.
      def shorten(text, max = 60)
        text.length > max ? "#{text[0, max - 3]}..." : text
      end

      # Creates and registers a Player.  Called with @mutex held.  Returns
      # the name.
      def start_player(name:, input:, description:, timeline_nodes:, start:, fade:)
        @next_serial += 1
        @players[@next_serial] = Player.new(
          serial: @next_serial,
          name: name,
          input: input,
          description: description,
          start: start,
          launch: start,
          timeline_nodes: timeline_nodes,
          started: false,
          slow_warned: false,
          gain: fade ? 0.0 : 1.0,
          ramp: nil,
          fade_in: fade,
          fading_out: false,
          keep: false,
          strip_level: initial_strip_level(name),
          strip_ramp: nil,
          asleep: false,
          ring: nil
        )

        @order.delete(name)
        @order << name
        name
      end

      # Keeps a stopped player for #resume if it was marked to be kept.
      # Called with @mutex held.
      def keep_stopped(p)
        end_ring(p)
        return unless p.keep
        @stopped.delete(p.name)
        @stopped[p.name] = p
      end

      # Names of players that are playing, waiting to start (also in the
      # change queue), or fading out.  Called with @mutex held.
      def names_in_use
        (@players.each_value.map(&:name) + @changes.select { |c| START_KINDS.include?(c.kind) }.map(&:subject)).uniq
      end

      # Removes one player by serial number, e.g. when it ends.  If +keep+ is
      # true and the player was stopped with #remove, it is kept for #resume.
      def retire(p, keep: false)
        @mutex.synchronize {
          end_ring(p)
          @players.delete(p.serial)
          keep_stopped(p) if keep
          @order.delete(p.name) unless @players.each_value.any? { |o| o.name == p.name }
        }
      end

      # Converts something playable into an Array of GraphNodes.
      def to_nodes(sound)
        case sound
        when String
          [MB::Sound.file_input(sound, resample: sample_rate.round)]
        when MB::Sound::GraphNode, MB::Sound::GraphNode::MultiOutput
          sound.outputs
        when Array
          unless !sound.empty? && sound.all? { |s| s.is_a?(MB::Sound::GraphNode) || s.is_a?(MB::Sound::GraphNode::MultiOutput) }
            raise ArgumentError, 'Pass an Array of GraphNodes, one per channel'
          end
          sound.flat_map(&:outputs)
        else
          raise ArgumentError, "Cannot play #{sound.class} in the background; use a GraphNode, a channel bundle, an Array of GraphNodes, or a filename"
        end
      end

      # Sets each node to the session's sample rate (see #sample_rate) if it
      # runs at another rate, so it plays at the right speed and its timeline
      # nodes count samples like the transport.  A node that can't change
      # its rate (e.g. a file input) is resampled instead.
      def match_rate(nodes)
        rate = sample_rate
        nodes.map { |n|
          next n if n.sample_rate == rate
          next n.resample(rate) unless n.respond_to?(:sample_rate=)

          begin
            n.sample_rate = rate
            n
          rescue GraphNode::SampleRateHelper::SampleRateSupportError, NotImplementedError
            n.resample(rate)
          end
        }
      end

      # Returns the timeline position in whole notes where a change at
      # launch point +point+ (a LaunchPoint, or nil for the default) lands,
      # counting from #now (a scheduled block's time inside one).
      # +timeline_nodes+ give :clip its clips.  +default+ is the alignment
      # used when +point+ gives no +on:+ (also after +in:+ or +at:+): :auto
      # (the default) for :now if nothing is playing or waiting to start
      # and :bar otherwise, an +on:+ value, or nil for none (and nil, right
      # away, if +point+ gives nothing).
      def launch_time(point, timeline_nodes = [], default: :auto)
        point ||= LaunchPoint::NONE
        point = LaunchPoint.on(point) if point.is_a?(Symbol)
        default = @players.empty? && !queued_start? ? :now : :bar if default == :auto
        replay = Session.perform&.[](:source) == :replay
        point.resolve(now: now, transport: @transport, default: default, clip_grid: -> { clip_grid(timeline_nodes) }, replay: replay)
      end

      # The time between moments when every timeline-aligned looping clip
      # is at its start (the least common multiple of their lengths), or a
      # bar if that is too long or there are no such clips.
      def clip_grid(timeline_nodes)
        lengths = timeline_nodes.grep(MIDI::ClipSource).map(&:clip).select { |c| c.looping? && !c.launch_aligned? }.map(&:length).uniq
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
      #
      # The player's strip (contract K7) runs in order: the fade ramp (in,
      # out, and across replacements), then the mute/solo level (see
      # Strip).  Ramps start on the exact sample of their time.  A player
      # that is silent because of a mute or solo sleeps (isn't rendered)
      # until it is unmuted.
      def render_player(p, mix, from, to, per_sample, count)
        return if p.start >= to

        rate = output.sample_rate.to_f
        base = @frame

        # A graph launched at time t starts on the sample whose window
        # [i, i + 1) holds t, where Notes nodes put an edge at t (see
        # Notes::Node), so a clip launched on its first note keeps it, and a
        # replaced graph stops before that sample
        offset = 0
        unless p.started
          offset = MB::M.max(((p.start - from) / per_sample).floor, 0)
          start = from + offset * per_sample
          p.timeline_nodes.each { |n| n.start_at(start, origin: start, launch: p.launch, transport: @transport) }
          p.start = start
          p.started = true
          p.ramp = Fades::Ramp.new(0.0, 1.0, base + offset, fade_frames(p.fade_in, rate)) if p.fade_in
        end

        ringing = p.ring&.active && !p.fade_out
        if p.stop_at && p.stop_at < to
          if ringing
            # Stops its notes on the exact sample of its stop time, then
            # rings out (see Tails)
            begin_ring(p, base, MB::M.max(((p.stop_at - from) / per_sample).floor, offset)) if p.ring.stop_frame.nil?
          elsif p.fade_out
            # Fades out from the exact sample of its stop time
            unless p.fading_out
              stop_idx = MB::M.max(((p.stop_at - from) / per_sample).floor, offset)
              start_fade_out(p, base + stop_idx, p.fade_out, rate)
            end
          elsif p.stop_at <= from
            return retire(p, keep: p.keep)
          end
        end

        frames = count - offset
        frames = MB::M.min(frames, ((p.stop_at - from) / per_sample).floor - offset) if p.stop_at && !p.fade_out && !ringing
        return retire(p, keep: p.keep) if frames <= 0

        # A muted player has nothing to ring out
        return retire(p, keep: p.keep) if ringing && p.ring.stop_frame && (p.asleep || (p.strip_level <= 0 && p.strip_ramp.nil?))

        # Sleeping (muted) players aren't rendered until their unmute ramp
        # starts; then their clips catch up with the timeline
        if p.asleep || (p.strip_level <= 0 && p.strip_ramp.nil?)
          wake = p.strip_ramp && p.strip_ramp.to > 0 ? MB::M.max(p.strip_ramp.start - base, offset) : nil
          if wake.nil? || wake >= offset + frames
            p.asleep = true
            fade_ramp(p, base + offset, frames) # keeps fades moving while asleep
            return finish_player(p, false, base + offset + frames)
          end

          if p.asleep || wake > offset
            wake_pos = from + wake * per_sample
            p.timeline_nodes.each { |n| n.start_at(wake_pos, origin: p.start, launch: p.launch, transport: @transport) }
            p.asleep = false
          end
          frames -= wake - offset
          offset = wake
        end

        # A mute ramp ending in this buffer: the graph stops on the ramp's
        # last frame (not the end of the buffer), so free-running
        # oscillators sleep at the same point whatever the buffer size
        if p.strip_ramp && p.strip_ramp.to <= 0
          silent_from = p.strip_ramp.start + p.strip_ramp.length
          if silent_from <= base + offset
            p.strip_level = 0.0
            p.strip_ramp = nil
            p.asleep = true
            fade_ramp(p, base + offset, frames)
            return finish_player(p, false, base + offset + frames)
          end
          frames = MB::M.min(frames, silent_from - (base + offset))
        end

        t = MB::U.clock_now
        data = p.input.read(frames)
        check_speed(p, MB::U.clock_now - t, frames)

        if data.nil? || data.empty? || data.all? { |d| d.nil? || d.empty? }
          retire(p)
          return
        end

        # A ringing tail stops on the sample where it has been quiet long
        # enough, or fades out once it has rung too long
        rung_out = false
        if ringing && p.ring.stop_frame
          cap_ring(p, base + offset + frames, rate)
          keep = follow_ring(p, data, base + offset, frames, rate)
          if keep < frames
            rung_out = true
            frames = keep
            if frames == 0
              note_rung_out(p, base + offset, rate)
              return retire(p, keep: true)
            end
          end
        end

        ramp = fade_ramp(p, base + offset, frames)
        strip = ramp_levels(p, :strip_level, :strip_ramp, base + offset, frames)
        ramp = ramp ? (strip ? ramp * strip : ramp) : strip

        mix.each_with_index do |m, c|
          d = data[c % data.length]
          next if d.nil? || d.empty?
          d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
          len = MB::M.min(d.length, frames)
          d = d[0...len]
          d = d * ramp[0...len] if ramp
          m[offset...(offset + len)] = m[offset...(offset + len)] + d
        end

        if rung_out
          note_rung_out(p, base + offset + frames, rate)
          return retire(p, keep: true)
        end

        # A short read means the graph ended
        ended = data.any? { |d| d.nil? || d.length < frames }
        finish_player(p, ended, base + offset + frames, to: to)

      rescue => e
        retire(p)
        raise if @raise_errors
        warn "Player #{p.name.inspect} (#{p.description}) stopped with an error: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
      end

      # Retires a player after a buffer if it ended, was cut off by its
      # replacement, or has faded out; puts a fully muted player to sleep.
      # +frame+ is the session frame after its last rendered sample.
      def finish_player(p, ended, frame, to: nil)
        # A replaced graph ends at its replacement's start unless it is
        # fading; a fade out ends at silence
        cut = to && p.stop_at && p.stop_at < to && !p.fade_out && !p.ring&.active
        faded = p.fading_out && p.ramp.nil? && p.gain <= 0

        if ended
          retire(p)
        elsif cut
          retire(p, keep: p.keep)
        elsif faded
          note_rung_out(p, frame, output.sample_rate) if p.ring&.active
          retire(p, keep: true)
        elsif p.strip_level <= 0 && p.strip_ramp.nil?
          p.asleep = true
        end
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

      # Warns once if a player takes most of the time available for its
      # buffer, which means it will soon cause dropouts for every player.
      def check_speed(p, elapsed, frames)
        return unless @realtime && !p.slow_warned

        load = sustained_load(p, elapsed, frames)
        if load
          p.slow_warned = true
          warn "Player #{p.name.inspect} (#{p.description}) is taking #{(100 * load).round}% of its audio buffer time; it may cause dropouts"
        end
      end

      # Buffers to ignore when a player or chain starts (resamplers and other
      # nodes are much slower on their first buffers).
      SLOW_WARMUP_BUFFERS = 5

      # Buffers to average when deciding whether a player is too slow.
      SLOW_WINDOW = 10

      # Records how long +record+ (a player or master chain with a +loads+
      # field) took for a buffer of +frames+, returning its average fraction
      # of the buffer time over the last SLOW_WINDOW buffers if that is over
      # 75% after SLOW_WARMUP_BUFFERS and a full window, or nil.
      def sustained_load(record, elapsed, frames)
        record.loads ||= { buffers: 0, recent: [] }
        record.loads[:buffers] += 1
        return nil if record.loads[:buffers] <= SLOW_WARMUP_BUFFERS

        recent = record.loads[:recent]
        recent << elapsed * output.sample_rate / frames
        recent.shift if recent.length > SLOW_WINDOW
        return nil if recent.length < SLOW_WINDOW # one spike isn't sustained

        average = recent.sum / recent.length
        average > 0.75 ? average : nil
      end

      # Starts the background rendering thread if it isn't running.
      def start_thread
        return if @thread&.alive?

        @thread = Thread.new do
          # Scheduled like interactive audio on macOS (QoS), so a busy
          # machine (e.g. waking the screen) doesn't starve the renderer
          FastAudio.boost_thread_priority

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
        @transport.bar_at(position).floor
      end
    end
  end
end
