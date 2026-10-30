require 'monitor'

require_relative 'launch_point'
require_relative 'gc_quiet'

require_relative 'session/journal'
require_relative 'session/names'
require_relative 'session/changes'
require_relative 'session/fades'
require_relative 'session/strip'
require_relative 'session/faders'
require_relative 'session/undo'
require_relative 'session/master'
require_relative 'session/tails'
require_relative 'session/markers'
require_relative 'session/seeks'
require_relative 'session/clip_swaps'
require_relative 'session/scheduler'
require_relative 'session/graph_view'
require_relative 'session/knobs'
require_relative 'session/clocks'
require_relative 'session/gestures'
require_relative 'session/decisions'
require_relative 'session/key_changes'
require_relative 'session/tempo_changes'
require_relative 'session/midi_in'
require_relative 'session/audio_recording'
require_relative 'session/stems'
require_relative 'session/cue'
require_relative 'session/monitor_trim'
require_relative 'session/safety_limiter'
require_relative 'session/buses'
require_relative 'session/racks'
require_relative 'session/ui_feed'
require_relative 'session/warming'
require_relative 'session/carry'

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
    # pauses when the last graph stops (see Sequence::Transport#seek), except
    # in offline renders waiting for scheduled blocks (see #advance_idle=).
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
      include Faders
      include Undo
      include Master
      include Tails
      include ClipSwaps
      include Seeks
      include GraphView
      include Knobs
      include Clocks
      include Gestures
      include Decisions
      include KeyChanges
      include TempoChanges
      include MidiIn
      include AudioRecording
      include Stems
      include MonitorTrim
      include SafetyLimiter
      include UIFeed
      include Warming
      include Buses # it extends Strip, Undo, and Seeks through super
      include Cue # last: it extends Strip, Undo, Seeks, and Buses through super

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
      # +asleep+ is true while a muted player isn't being rendered;
      # +asleep_reads+ caches what it still reads (see Strip#asleep_reads);
      # +read_to+ is the session frame its graph has been read up to (see
      # Strip#read_kept_graphs).
      #
      # +ring+ is a Tails::Ring while the player rings out after a stop
      # (see Tails).
      #
      # +cpu+ is the seconds its graph took since the terminal UI's feed
      # last read it (only counted while a feed is attached; see UIFeed).
      Player = Struct.new(
        :serial, :name, :input, :description, :start, :launch, :stop_at, :timeline_nodes,
        :started, :slow_warned, :loads, :gain, :ramp, :fade_in, :fade_out, :fading_out, :keep,
        :strip_level, :strip_ramp, :asleep, :ring, :asleep_reads, :read_to, :cpu, :cue, :waited,
        :level_buf, # ([value, frozen SFloat] of a steady level; Faders#fader_levels)
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

      class << self
        # Whether realtime Sessions warn about players and master chains that
        # take most of their buffer time (#check_speed, #check_master_speed).
        # On by default; MB_SOUND_SPEED_WARNINGS=0 turns it off, which the
        # specs do (the warning depends on machine load, so a busy machine
        # would make unrelated script specs print it).
        attr_accessor :speed_warnings
      end
      self.speed_warnings = ENV['MB_SOUND_SPEED_WARNINGS'] != '0'

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

      # Frames this Session has rendered (it grows by a buffer when the
      # render thread finishes one; others may read it without a lock: the
      # sound-design screen's previews start their heavier steps right
      # after a buffer, UI::PatchRender).
      def frames_rendered = @frame

      # The default master bus gain (-10 dB), leaving headroom for mixes of
      # full-scale oscillators.
      DEFAULT_MASTER_GAIN = 10 ** (-10 / 20.0)

      # The linear gain applied to the whole mix: before the master effects
      # by default (pre-chain, so a limiter's ceiling holds whatever the
      # gain), or after them with #master_gain_post (the placement before
      # 2026-10-13), and before the output and taps either way.  Without
      # master effects the two are the same.  See PlaybackMethods#master_gain.
      attr_reader :master_gain

      # Sets the master bus gain (linear; e.g. `-6.db`).
      def master_gain=(gain)
        raise ArgumentError, "Master gain must be a Numeric (got #{gain.inspect})" unless gain.is_a?(Numeric)
        @master_gain = gain.to_f
      end

      # True if the master gain applies after the master effects (post, like
      # a DAW's post-fader inserts switched off: the chain hears the mix at
      # unity, and the gain scales its output, so a limiter's ceiling moves
      # with it), false (the default) for before them (see #master_gain).
      def master_gain_post?
        @master_gain_post
      end

      # Sets where the master gain applies (see #master_gain_post?).
      def master_gain_post=(post)
        raise ArgumentError, "master_gain_post must be true or false (got #{post.inspect})" unless post == true || post == false
        @master_gain_post = post
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
      # +:monitor+ - If true, the output hears the monitor trim (see
      #              MonitorTrim; by default when +:realtime+).
      # +:safety_limiter+ - If true, the output goes through a transparent
      #                     -1 dBFS limiter while no master chain is set
      #                     (see SafetyLimiter; by default when +:realtime+).
      def initialize(output: nil, transport: Sequence.transport, tuning: Tuning.default, master_gain: DEFAULT_MASTER_GAIN, master_gain_post: false, channels: 2, buffer_size: nil, realtime: true, raise_errors: false, fade_in: nil, fade_out: nil, monitor: nil, cue_output: nil, safety_limiter: nil)
        @transport = transport
        @per_sample_cache = nil # (see #span_per_sample)
        @span_mix_bufs = nil # (see #span_mix)
        @reuse_mix = false # (see #process_buffer)
        @tail_range = nil # (see Tails#abs_peak)
        @taps_copy = nil # (see #call_taps)
        @master_copy = nil # (see Master#process_master)
        @bus_chain_copies = {}.compare_by_identity # (see Buses#run_bus_chains)
        @bus_shared_copies = {}.compare_by_identity # (see Buses#bus_read_shared)
        @routed_buses = [] # (see Buses#render_routed)
        @send_rows = {}.compare_by_identity # (see Buses#send_rows)
        @only_keys = {} # (see Buses#bus_signal)
        @chain_results = nil # (see Master#master_chain_output)
        @chain_data = {}.compare_by_identity
        @master_out_bufs = nil # (see Master#process_master)
        @tuning = tuning
        self.master_gain = master_gain
        self.master_gain_post = master_gain_post
        self.fade_in = fade_in
        self.fade_out = fade_out
        @replace_declick = nil
        @output = output
        @channels = channels
        @buffer_size = buffer_size
        @realtime = realtime
        @advance_idle = false
        @raise_errors = raise_errors
        @paused = false

        @players = {}
        @stopped = {}
        @last_carry = nil # (the last swap's Carry::Plan; see #last_carry)
        @taps = []
        @master_chains = []
        @order = []
        @next_serial = 0
        @mutex = Mutex.new
        @thread = nil
        @closed = false
        @plan_deferral = nil # (see #plan_deferral)
        @generation = @transport.generation
        @scheduler = Scheduler.new(self, realtime: realtime, raise_errors: raise_errors)

        init_changes
        init_strip
        init_faders
        init_undo
        init_knobs
        init_clocks
        @smoothed_gestures = Gestures::Smoothed.new
        @replayed_gestures = nil
        init_decisions
        init_midi_in
        init_audio_recording
        init_monitor(monitor.nil? ? realtime : monitor)
        init_safety_limiter(safety_limiter.nil? ? realtime : safety_limiter)
        init_buses
        init_cue(cue_output)
        init_warming
        @names = Names.new
        @racks = Racks.new(self)
        @arrangement = nil

        # Set later, in varying orders (here so every Session has one
        # instance variable layout; see GraphNode::IvarPreset)
        @exact_lanes = nil
        @input_lock = nil
        @ring = nil
        @stems = nil
        @master_block = nil
        @master_preset = nil
        @mastering_override = nil
        @mastering_trim = nil
        @mastering_capture = nil
        @master_playing = nil
        @markers = nil
        @epoch = nil
        @replay_epoch = nil
        @span_players = nil
        @span_graphs = nil
        # The span being rendered, for taps that stamp what they see (see
        # Session.span; MIDI::Stream#spy)
        @span = Span.new(self, 0, 0r, 0r, false, 48000, 0)
        @player_frame = nil
        @asleep_ids = nil # (unused since dropouts-2; see Strip#span_graphs)
        @span_graph_scratch = nil
        @kept_scratch = nil # (see Strip#read_kept_graphs)
        @span_player_list = nil # (see #render_span)
        @span_step = nil # (see #span_step)
        @bus_zero_seg = nil # (see Buses#run_bus_chains)
        @asleep_graphs = nil
        @bus_span_count = nil
        @bus_span_buses = nil
        @load = nil
      end

      # The Session's top-level names (see Names).
      attr_reader :names

      # Named racks (see Session::Racks and MB::Sound::RackMethods).
      attr_reader :racks

      # The marker table (see Markers), created when first needed.
      def markers
        @markers ||= Markers.new(self)
      end

      # The Set layer of this Session (tracks and scenes; see
      # MB::Sound::Arrangement), created when first needed.
      def arrangement
        @arrangement ||= Arrangement.new(self)
      end

      # The Carry::Plan of the last graph swap that carried running state
      # (a bind's or a build knob's rebuild), or nil: what matched.
      attr_reader :last_carry

      # True if a player named +name+ will be playing once the changes
      # waiting in the change queue have landed.
      def playing_after_queue?(name)
        @render_lock.synchronize {
          playing = @mutex.synchronize { @players.each_value.any? { |p| p.name == name && p.current? } }
          @changes.each do |c|
            next unless c.subject == name
            playing = true if START_KINDS.include?(c.kind) && c.kind != :restore
            playing = false if c.kind == :stop
            # An undo's :restore puts back a player (its +starts+ are the
            # restored graph's timeline nodes) or none (nil +starts+), so
            # e.g. undoing `arm` counts its monitor as stopping
            playing = !c.starts.nil? if c.kind == :restore
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
      # channel), a sound filename, or anything else Playable.graph converts
      # (samples, clips, instruments, audio arrays, ...).  Returns the player's name for #remove:
      # +:name+ if given, or else the lowest unused Integer.
      #
      # If a graph is already playing under +:name+, it keeps playing until
      # the new graph starts, then crossfades into it over +:fade+ bars, by
      # default a 5 ms declick (Fades::DECLICK_SECONDS) starting on that
      # exact sample; +fade: 0+ cuts on the exact sample.
      #
      # +:fade+ also fades the new graph in over that many bars.  If not
      # given, new graphs fade in over #fade_in bars, and replacements
      # crossfade over the declick time.  Pass 0 or false for no fade.
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
      #
      # +:to+ and +:send+ set the name's routing (see Buses#route): the bus
      # its main out feeds, and its sends (bus name => level).
      #
      # +:warm+ is a Proc that builds a copy of the graph (a track's patch
      # again), for warming its code before it lands (see Warming; without
      # it, a copy is loaded from the graph's recipe).
      def add(sound, at: nil, on: nil, in: nil, name: nil, fade: nil, description: nil, start_time: nil, to: :keep, send: nil, warm: nil, carry: false)
        raise IOError, 'Session is closed' if @closed
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, "Player names must be Symbols or Integers (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol) || name.is_a?(Integer)
        explicit_fade = !fade.nil?
        fade = bars_or_nil(fade)

        # A trigger track plays signals as they are (an envelope key isn't made
        # audible: nobody hears a trigger track; see Buses#route)
        sound = Playable::Graph.new(nodes: sound.outputs, description: sound.to_s, ends: nil, note: nil) if sound.is_a?(Envelope) && name && trigger_track?(name)
        playable = Playable.graph(sound, sample_rate: sample_rate)
        nodes = match_rate(playable.nodes)
        @mastering_capture&.saw(nodes) # (a targeted render's passes; see Mastering::Targeting)
        adopt_knobs(nodes, player: name) # graph documents' knobs and rack knobs join the Session (see Knobs#adopt_knobs)
        adopt_clocks(playable.nodes) # graph documents' clocks too (see Clocks#adopt_clocks)
        input = MB::Sound::GraphNodeInput.new(nodes)
        Plan.install(nodes) # fused plans (see MB::Sound::Plan), after the input's branches
        timeline_nodes = nodes.flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq
        # The graph's Synths (see #align_grids), first-buffer setups (e.g.
        # drum voices' skipping), and node set (see Strip#graph_node_set),
        # from one walk here, on the thread that builds it, rather than by
        # the render thread where it waits and starts
        input.prime
        description = shorten(description || playable.description)

        # Its code compiled here rather than where it lands (see Warming)
        warm_graph(name, nodes, warm, warm_time(point, start_time))

        time = start_time ? start_time.to_r : launch_time(point, timeline_nodes)

        # The running state to carry from the graph this one replaces (see
        # Carry): matched here, copied on the swap frame
        carried = nil
        if carry && name
          old = @mutex.synchronize { @players.each_value.find { |p| p.name == name && p.current? } }
          carried = Carry.plan(old.input, nodes) if old
        end

        @render_lock.synchronize {
          name = @mutex.synchronize {
            name ||= (1..).find { |i| !names_in_use.include?(i) }
            @order.delete(name)
            @order << name
            name
          }

          # Routing, readers of buses and players, and spies for readers of
          # named nodes in this graph (see Buses)
          route(name, to: to, send: send) unless to == :keep && send.nil?
          bind_bus_taps(nodes, name) or return nil
          attach_bus_spies(name, nodes) if @bus_only.key?(name)

          change(:bg, name, time, data: { description: description, fade: fade }, starts: timeline_nodes, graph: input, split: !carried.nil?) { |t|
            add_now(name: name, input: input, description: description, timeline_nodes: timeline_nodes, start: t, fade: fade, explicit_fade: explicit_fade,
                    carry: carried)
          }
          end_cue_at_start(name, time) # (see Cue)
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
      # may replay the start of an old tail, except nodes the graph shares
      # with other graphs in the Session, which it kept in step with while
      # stopped (see Strip#read_kept_graphs).
      def resume(name = nil, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
        point = LaunchPoint.of(binding) or return nil
        fade = fade.nil? ? @fade_in : bars_or_nil(fade)

        # A disarmed track's monitor stays stopped (see Arrangement::Arm:
        # it plays exactly while its track is armed); `arm` starts it
        if name && disarmed_monitor?(name)
          track = Session::Name.monitored(name)
          return MB::Sound.live_error(ArgumentError.new("#{name.inspect} is track #{track.inspect}'s live monitor, which plays while the track is armed (arm #{track.inspect})"))
        end

        @render_lock.synchronize {
          p = @mutex.synchronize {
            name ||= @stopped.keys.reject { |n| disarmed_monitor?(n) }.last
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

      # True if +name+ is the live monitor of a track that isn't armed (see
      # Session::Name.monitor).
      private def disarmed_monitor?(name)
        track = Session::Name.monitored(name)
        !track.nil? && !(@arrangement&.armed?(track))
      end

      # Returns a Hash from name to description of stopped graphs that can be
      # resumed (see #resume), most recently stopped last.
      def stopped
        @mutex.synchronize { @stopped.transform_values(&:description) }
      end

      # Discards the named stopped graphs (all of them if no names are
      # given), so they can no longer be resumed: a :forget change (see
      # Changes) for each, landing now or at +time+ (whole notes; a
      # scheduled block's time), and undoable.  Returns the names
      # discarded (or to be discarded).
      def forget(*names, time: nil)
        time = nil if time && time.to_r <= @transport.position
        @render_lock.synchronize {
          names = @mutex.synchronize { @stopped.keys } if names.empty?
          names.select { |n|
            next false unless time || @mutex.synchronize { @stopped.key?(n) }
            change(:forget, n, time) { |_t|
              @mutex.synchronize { @stopped.delete(n) }
              prune_rack_knobs # (a forgotten player's rack knobs leave the session)
            }
            true
          }
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
      # and then every +period+ whole notes if given.  Returns a
      # Scheduler::Handle (prints when it runs; #cancel).  +owner+ is who
      # scheduled it (:user, :form, :take, :script; see Scheduler::Entry)
      # and +label+ the command to show.  See Scheduler for how and when
      # blocks run (and Scheduler::Entry for +:exact+).
      def schedule(time, period: nil, description: nil, epoch: nil, owner: :user, label: nil, exact: false, &block)
        @scheduler.schedule(time, period: period, description: description, epoch: epoch, owner: owner, label: label, exact: exact, &block)
      end

      # Starts the background rendering thread of a realtime session (and
      # opens its output) if it isn't running, so scheduled blocks run even
      # before anything plays (e.g. a song form's first section).
      def ensure_running
        return unless @realtime && !@closed
        output
        start_thread
      end

      # Removes scheduled blocks (Scheduler::Handles or ids; every block
      # scheduled with ScheduleMethods if none are given).  Returns the
      # Handles that were cancelled.
      def cancel(*ids)
        @scheduler.cancel(*ids)
      end

      # The Scheduler::Handles of blocks that haven't run yet (and repeating
      # blocks), soonest first.
      def scheduled
        @scheduler.scheduled
      end

      # The scheduler's panic button (see Scheduler#reset): stops the song
      # form playing (if any), cancels every scheduled block except a take's
      # replayed lines, and restarts the scheduler thread if it died or a
      # block is stuck (waiting up to +wait+ seconds for it first).  Returns
      # a Hash with :cancelled (Handles), :form (true if a form was
      # stopped), and :restarted (nil, or what was wrong).
      def reset_scheduler(wait: Scheduler::RESET_WAIT)
        pb = @arrangement&.playback
        form = !!(pb && !pb.ended?)
        pb.stop if form
        @scheduler.reset(wait: wait).merge(form: form)
      end

      # Returns true if a scheduled block's time has come (so it will run on
      # the next buffer even if nothing is playing).
      def schedule_due?
        @scheduler.due?
      end

      # Returns true if something scheduled is still to come, whatever its
      # time: a scheduled block waiting to run (any, or only one-shot blocks
      # if +:repeating+ is false; with +:before+, only blocks timed before
      # that timeline position), a block that ran ahead of its time (see
      # #lookahead) whose time hasn't come, or a queued change or tempo
      # change (with +:before+, only those timed before it).  PlaybackMethods#render keeps rendering while nothing plays
      # as long as this is true.
      def schedule_waiting?(repeating: true, before: nil)
        @render_lock.synchronize {
          @changes.any? { |c| before.nil? || c.time.nil? || c.time < before } ||
            @scheduler.waiting?(@transport.position, repeating: repeating, before: before)
        }
      end

      # True if this offline session's timeline keeps moving while nothing
      # is playing (see #advance_idle=).
      def advance_idle?
        @advance_idle
      end

      # If true, an offline Session (+realtime: false+) keeps its timeline
      # moving while nothing is playing, so scheduled blocks still come due
      # (set by PlaybackMethods#render while it waits for blocks scheduled
      # ahead, rendering silence until they start something).  Realtime
      # sessions always pause while idle; setting it on one raises.
      def advance_idle=(value)
        raise ArgumentError, 'Only offline (realtime: false) sessions can advance while idle' if value && @realtime
        @advance_idle = value ? true : false
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

      # Each current player's graph by name (for debug_dump; takes the
      # render lock).
      def debug_graphs
        @render_lock.synchronize { @mutex.synchronize { @players.values.select(&:current?).to_h { |p| [p.name, p.input] } } }
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
      # e.g. for plotting.  On a realtime Session's render thread the
      # arrays are reused for the next buffer, so a block that keeps them
      # keeps copies (dropouts-2; #process_buffer's callers get new ones).
      # The block runs on the rendering thread, so it must return quickly.  Returns the block, for #remove_tap.
      def add_tap(&block)
        raise ArgumentError, 'Pass a block to tap the mix' unless block
        @mutex.synchronize { @taps << block }
        block
      end

      # The session frame of the first sample the player being rendered
      # reads in this span (a player starting or waking partway through a
      # span starts there), or nil outside a player's read.  MIDI input
      # taps place the span's events from it (see MidiInput::Tap).
      attr_reader :player_frame

      # True if Synths this Session starts free lanes by whole grid cells,
      # the same at any buffer size (Synth#exact_lanes?; take replays and
      # render(exact_lanes: true) turn it on).  Applies to players started
      # after it is set.
      attr_accessor :exact_lanes

      # How sums built for this Session end (GraphNode::Mixer.ring_mode):
      # nil or :all (the default; sums ring until every input has ended)
      # or :first (or false; a sum ends with its first input to end), for
      # graphs built in its context from now on: a render block
      # (render(ring: :first)), scheduled blocks, and track patches.
      # GraphNode#ring sets one sum.
      attr_reader :ring

      def ring=(mode)
        @ring = mode.nil? ? nil : GraphNode::Mixer.ring_value(mode)
      end

      # Stops calling a block given to #add_tap.
      def remove_tap(block)
        @mutex.synchronize { @taps.delete(block) }
      end

      # The background rendering thread (nil before #add starts it), for
      # measurements like the terminal UI's GVL probe (bin/ui_demo.rb).
      def render_thread
        @thread
      end

      # A one-line summary (ux-fix-1): the default #inspect printed every
      # player's graph with its buffers.  #inspect_full is the old dump.
      def inspect
        mode = @realtime ? 'realtime' : 'render'
        count = @players&.size.to_i
        "#<Session #{mode}, #{count} player#{count == 1 ? '' : 's'}, #{MB::M.sigformat(@transport&.bpm.to_f)} bpm>"
      end

      def inspect_full
        Kernel.instance_method(:inspect).bind_call(self)
      end

      def pretty_print(q)
        q.text(inspect)
      end

      # True if this Session plays in real time through its output (a
      # render thread paced by the output), false for renders driven by
      # #process_buffer.
      def realtime?
        @realtime
      end

      # True while a realtime Session is paused (see #paused=).
      def paused? = @paused

      # Pauses (true) or resumes (false) a realtime Session's render
      # thread: while paused it writes silence to the output and renders
      # nothing, so the timeline, the players, and scheduled blocks wait
      # where they are (a script's screen pauses a song with Space; see
      # ScriptRunner's --ui).  Renders (#process_buffer) don't pause.
      def paused=(on)
        raise ArgumentError, 'Only a realtime Session pauses (renders call process_buffer)' if on && !@realtime
        @paused = !!on
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
        @output ||= begin
          channels, cue = output_channels # (twice the channels for CUE ports; see Cue)
          cue > 0 ? MB::Sound.output(channels: channels, cue: cue, shared: false) : MB::Sound.output(channels: channels, shared: false)
        end
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
      # through the master effects (see #master), writes it to the output
      # (with the monitor trim, see MonitorTrim), and advances the timeline
      # (unless idle; see #advance_idle=).  Returns the mix (an Array of Numo::SFloat, one per
      # channel) before the monitor trim.
      #
      # With +until_pos+ (a timeline position, whole notes) the buffer ends
      # on the first frame at or past it, if that comes first (renders'
      # end bar: the frame is the same at any buffer size even while the
      # tempo moves, since it is found in the span holding it, at that
      # span's tempo; omnibus16: renders estimated it from the tempo at the
      # buffer's start and ended 1-2 frames apart at 367 and 800 frames).
      # The mix is then shorter than +count+.
      def process_buffer(count = buffer_size, until_pos: nil)
        started = MB::U.clock_now
        # The render thread's mix is reused from buffer to buffer (the
        # output, taps, recordings, and the UI feed copy what they keep;
        # dropouts-2: two new SFloats a buffer were ~470 KB/s of garbage
        # at 256 frames); callers of #process_buffer keep what it returns
        @reuse_mix = Thread.current.equal?(@thread)

        mix = @render_lock.synchronize {
          # A seek (or its undo) landing inside the buffer splits it: the
          # frames before it, then the rest from the new position (see
          # Seeks), so it lands on the same frame at any buffer size
          # (no Array for the usual one span; dropouts-2)
          first = nil
          parts = nil
          remaining = count
          while remaining > 0
            @scheduler.apply_timed_changes
            commit_due_seeks unless @changes.empty?
            # A moving tempo (a ramp, a followed knob) plays in tempo cells
            # (see TempoChanges)
            cell = tempo_cell(remaining)
            per_sample = span_per_sample
            # A take replay's lines run before the span whose time they were
            # typed in, like live lines typed between buffers, so a tempo
            # they set covers the whole span (see Scheduler::Entry#exact)
            from = @transport.position
            to = from + span_step(remaining, per_sample)
            if @scheduler.dispatch_exact(from, to)
              @scheduler.apply_timed_changes
              commit_due_seeks unless @changes.empty?
              cell = tempo_cell(remaining)
              per_sample = span_per_sample
              to = nil
            end
            n = (@changes.empty? ? nil : frames_before_seek(remaining, per_sample)) || remaining
            n = cell if cell && cell < n
            last = false
            if until_pos
              left = until_pos - @transport.position
              break if left <= 0

              k = (left / per_sample).ceil
              if k <= n
                n = k
                last = true
              end
            end
            # (the span's end, computed once when the span is the rest)
            r = render_span(n, per_sample, n == remaining && @transport.position.equal?(from) ? to : nil)
            if first.nil?
              first = r
            else
              (parts ||= [first]) << r
            end
            remaining -= n
            break if last
          end
          count -= remaining
          @ui_feed.capture(self) if @ui_feed&.wants_capture? # players, buses, chains, while they can't change
          # (no spans for a buffer of 0 frames: an empty mix, as before)
          next [] if first.nil?
          parts.nil? ? first : parts.transpose.map { |chans| chans.reduce { |a, b| a.concatenate(b) } }
        }

        return mix if count == 0 # (until_pos: already there)

        # How busy rendering is (before the output blocks), for deciding
        # whether master chains can crossfade
        @load = (MB::U.clock_now - started) * output.sample_rate / count

        # Post-chain master gain (pre-chain is in #render_span)
        mix = mix.map { |c| c * @master_gain } if @master_gain_post && @master_gain != 1

        # The safety limiter (without a master chain) and the monitor trim
        # reach only the output (see SafetyLimiter, MonitorTrim)
        output.write(monitored(cue_frame(safety_limited(mix), count))) # with CUE (see Cue)
        record_mix(mix, @frame - count)
        call_taps(mix)
        @ui_feed&.publish(self, mix, count, @load)
        mix
      end

      # +count+ * +per_sample+ (whole notes), kept while both hold (a
      # Rational every buffer otherwise).
      def span_step(count, per_sample)
        c = @span_step
        return c[2] if c && c[0] == count && c[1].equal?(per_sample)

        v = count * per_sample
        @span_step = [count, per_sample, v]
        v
      end
      private :span_step

      # Renders +count+ frames (one span of #process_buffer): scheduled
      # blocks, changes landing in the span, players, and the master chain.
      # Advances the timeline and the frame counter.  Returns the mix.
      # Called with the render lock held.
      def render_span(count, per_sample, to = nil)
        from = @transport.position
        to ||= from + count * per_sample
        old_span = Thread.current[:mb_sound_span]
        old_deferral = Thread.current[:mb_sound_plan_deferral]
        @span.frame = @frame
        @span.pos = from
        @span.per_sample = per_sample
        @span.moving = @advance_idle || !idle?
        @span.sample_rate = sample_rate
        @span.run = @run_frame
        Thread.current[:mb_sound_span] = @span

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

        # Offline renders waiting for scheduled blocks keep time while idle
        # (see #advance_idle=); otherwise the timeline pauses
        keep_time = @advance_idle
        @scheduler.dispatch(from, to, playing: keep_time || !idle?)

        # MIDI input lands on exact frames before changes (a recording
        # closing in this span needs its events) and graphs read it
        pump_midi(@frame, count, from, per_sample)

        # Changes landing in this span, after scheduled blocks (which may
        # queue some for it)
        commit_due(from, to, per_sample)

        # Knobs move before anything reads them (see Knobs)
        advance_knobs(@frame, count) unless @knobs.empty?
        # Clocks: tempo points and variable-speed cells (see Clocks)
        begin_clock_span(count, per_sample)

        # Plan rebuilds finished elsewhere land here, between blocks, and
        # graphs rendered in this span defer theirs (see Plan::Rebuild)
        deferral = plan_deferral
        deferral&.apply
        Thread.current[:mb_sound_plan_deferral] = deferral

        # (a reused copy, taken under the lock: every span; dropouts-2)
        players = (@span_player_list ||= [])
        @mutex.synchronize { players.clear; @players.each_value { |p| players << p } }
        @span_players = players # for Strip#asleep_reads
        @span_graphs = nil
        # Graphs waiting to start keep in step with shared nodes (see Strip)
        catch_up_waiting(players)

        mix = span_mix(count)
        begin_cue_span(count)
        playing = !players.empty? || queued_start?
        routed = @routed_span = routed?
        if routed
          # Buses, sends, and readers: dependency order (see Buses)
          render_routed(players, mix, from, to, per_sample, count, @frame, playing)
        elsif @stems
          render_players_with_stems(players, mix, from, to, per_sample, count, @frame)
        else
          players.each do |p|
            render_player(p, mix, from, to, per_sample, count)
          end
        end

        # Graphs kept for #resume or #undo keep their shared nodes in step
        read_kept_graphs(@frame + count)

        moving = playing || keep_time
        if moving
          whole_notes = to - from
          @transport.advance_span(from, to, whole_notes)
          end_clock_span(count, whole_notes, moving)
        end
        # Pre-chain master gain (the default; see #master_gain_post?)
        # (in place on this span's own mix buffers when the kernel takes
        # them: the same float products as Numo's c * gain)
        if !@master_gain_post && @master_gain != 1
          g = @master_gain
          i = 0
          while i < mix.length
            c = mix[i]
            mix[i] = c * g unless FastArithmetic.scale(c, g)
            i += 1
          end
        end
        begin_bus_read(0) if routed # master chains reading buses or players
        mix = process_master(mix, from, to, per_sample, count, playing: playing, seeked: seeked)
        # (without a master chain the mix itself leaves the span: callers
        # keep what #process_buffer returns, so it can't be the reused one,
        # except on the render thread; see #process_buffer)
        mix = mix.map(&:dup) if !@reuse_mix && mix.equal?(@span_mix_bufs)
        end_cue_span(mix, count) # the phones mix (see Cue)

        @frame += count
        # A moving tempo is read for the next frame now, so changes landing
        # between buffers (console lines) and inside spans (take replays at
        # other buffer sizes) see the same tempo (see TempoChanges)
        tempo_cell(1) if moving && @transport.tempo_moves?
        @transport_record = transport_record_for(moving)
        mix
      ensure
        @knob_frame = nil
        Thread.current[:mb_sound_span] = old_span
        Thread.current[:mb_sound_plan_deferral] = old_deferral
      end
      private :render_span

      # The Plan::Deferral for plan rebuilds in this span, or nil to rebuild
      # at once (see Plan.rebuilds: by default a realtime Session's render
      # thread defers them).
      def plan_deferral
        case Plan.rebuilds
        when :inline
          nil
        when :auto
          return nil unless @realtime && Thread.current.equal?(@thread)

          @plan_deferral = nil if @plan_deferral&.mode != :thread
          @plan_deferral ||= Plan::Deferral.new(@render_lock)
        when :background
          @plan_deferral = nil if @plan_deferral&.mode != :thread
          @plan_deferral ||= Plan::Deferral.new(@render_lock)
        when :next_span
          @plan_deferral = nil if @plan_deferral&.mode != :next_span
          @plan_deferral ||= Plan::Deferral.new(@render_lock, mode: :next_span)
        end
      end
      private :plan_deferral

      # The Plan::Deferral this Session's renders defer plan rebuilds to
      # (stats and specs), or nil before one did.
      def plan_deferral_used
        @plan_deferral
      end

      # The span's mix buffers, zeroed: reused from span to span, since a
      # master chain reads the mix and returns its own buffers (the mix
      # leaves the span only without one; see #render_span; alloc-2).
      def span_mix(count)
        bufs = @span_mix_bufs
        if bufs.nil? || bufs.length != @channels || bufs.any? { |b| b.length != count || b.frozen? || !b.is_a?(Numo::SFloat) }
          return @span_mix_bufs = Array.new(@channels) { Numo::SFloat.zeros(count) }
        end
        bufs.each { |b| BufferHelper.zero(b) }
        bufs
      end
      private :span_mix

      # Whole notes per output sample at the transport's tempo (exact;
      # kept until the tempo or the output rate changes).
      def span_per_sample
        wnps = @transport.whole_notes_per_second
        rate = output.sample_rate
        c = @per_sample_cache
        return c[2] if c && c[0].equal?(wnps) && c[1] == rate
        (@per_sample_cache = [wnps, rate, wnps / rate.to_r].freeze)[2]
      end
      private :span_per_sample

      # The span a Session is rendering on this thread (frame and timeline
      # position of its first sample, whole notes per sample, whether the
      # timeline moves, and the sample rate), or nil outside a render.
      # Taps use it to stamp what they see with the Session clock
      # (MIDI::Stream#spy; Span#stamp).  Read it, don't keep it: it changes
      # every span.
      Span = Struct.new(:session, :frame, :pos, :per_sample, :moving, :sample_rate, :run) do
        # A Stamp for the sample +offset+ frames into the span.
        def stamp(offset = 0)
          Stamp.at(moving ? pos + offset * per_sample : pos, session.transport, frame: frame + offset)
        end
      end

      def self.span
        Thread.current[:mb_sound_span]
      end

      # Stops the background and scheduler threads and closes the output.
      def close
        return if @closed
        @closed = true
        ExitClose.unregister(self)
        @output.release_writer if @output.respond_to?(:release_writer) # (a virtual clock's; NullOutput)
        @thread&.join(5)
        @output.end_stream if @output.respond_to?(:end_stream) # (DeviceOutput: no concealment of the end)
        close_recordings
        midi_inputs.each_value { |m| m.input = nil unless m.replaying? }
        @scheduler.close
        @plan_deferral&.close
        @output&.close
        # (the graphs stay; see Strip.structure_check)
        check_structure! if Strip.structure_check
      end

      # Returns true if #close was called.
      def closed?
        @closed
      end

      private

      # Starts a graph built by #add at timeline position +start+, handing
      # over from the graph it replaces (applied by the change queue).
      def add_now(name:, input:, description:, timeline_nodes:, start:, fade:, explicit_fade:, carry: nil)
        @mutex.synchronize {
          @stopped.delete(name)

          replacing = @players.each_value.any? { |p| p.name == name && p.current? && p.started }
          # A replacement crossfades over the declick time (5 ms, exact
          # frames, like undo's restores; ux-r3 item 5: a hard cut between
          # two unrelated graphs clicked), unless given a fade (0: cut)
          fade = replacing ? (replace_declick ? declick_bars : nil) : @fade_in unless explicit_fade

          # Carried state (see Carry): the old graph has played up to this
          # frame (the change split the buffer here); when every stateful
          # node matched, the new graph continues its samples (a cut), else
          # the two crossfade over the declick time
          if carry && replacing && @players.each_value.any? { |p| p.name == name && p.current? && p.started && p.input.equal?(carry.old_input) && !p.asleep }
            Carry.apply(carry)
            # (else the declick crossfade: the nodes that start fresh)
            fade = carry.full? ? nil : declick_bars
            @last_carry = carry
          end

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
                note_retired(p)
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
              note_retired(p)
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
        start_player_spies(name, input) # (readers' spies; see Buses)
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
          ring: nil,
          cue: initial_cue_levels(name) # (see Cue)
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
          note_retired(p)
          keep_stopped(p) if keep
          @order.delete(p.name) unless @players.each_value.any? { |o| o.name == p.name }
        }
      end

      # Converts something playable into an Array of GraphNodes, one per
      # channel (see Playable.graph: graphs, bundles, Arrays, files,
      # samples, clips, instruments, ...).
      def to_nodes(sound)
        Playable.nodes(sound, sample_rate: output_open? ? sample_rate : 48000) # (without opening the output)
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
      #
      # +stem+ (stems with routing; see Buses#render_routed) gets the
      # player's main out wherever it goes.
      def render_player(p, mix, from, to, per_sample, count, stem: nil)
        if p.start >= to
          # (a started graph waiting for its start again after a backward
          # seek: clocks keep running meanwhile; see Clocks)
          p.waited = true if p.started
          return
        end

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
          align_grids(p, base + offset)
          catch_up_kept(p, base + offset) # a graph kept since it stopped
          catch_up_started(p, offset) # a graph that waited to start
        end

        if p.waited || p.start > from
          # The timeline jumped back before its start (in an earlier span,
          # or just before it in this one): it plays again from the sample
          # holding its start, as on its first start (a clipless graph
          # started at the span's start before omnibus16, so a 367-frame
          # replay played it up to a buffer early), and clocked clips and
          # loops resync to their clocks there
          p.waited = false
          offset = MB::M.max(((p.start - from) / per_sample).floor, 0)
          again = from + offset * per_sample
          if offset > 0
            p.timeline_nodes.each { |n| n.start_at(again, origin: p.start, launch: p.launch, transport: @transport) }
          end
          p.timeline_nodes.each { |n| n.clock_resync(again) if n.respond_to?(:clock_resync) }
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

        # A player that a sidechain reads keeps rendering while muted (see
        # Buses#bus_source?), waking here if it slept before
        sidechained = @routed_span && bus_source?(p.name)
        if sidechained && p.asleep
          wake_pos = from + offset * per_sample
          p.timeline_nodes.each { |n| n.start_at(wake_pos, origin: p.start, launch: p.launch, transport: @transport) }
          p.asleep = false
        end

        # Sleeping (muted) players aren't rendered until their unmute ramp
        # starts; then their clips catch up with the timeline
        if !sidechained && (p.asleep || (p.strip_level <= 0 && p.strip_ramp.nil?))
          wake = p.strip_ramp && p.strip_ramp.to > 0 ? MB::M.max(p.strip_ramp.start - base, offset) : nil
          if wake.nil? || wake >= offset + frames
            p.asleep = true
            fade_ramp(p, base + offset, frames) # keeps fades moving while asleep
            read_while_asleep(p, frames)
            p.read_to = base + offset + frames
            return finish_player(p, false, base + offset + frames)
          end

          if p.asleep || wake > offset
            wake_pos = from + wake * per_sample
            p.timeline_nodes.each { |n| n.start_at(wake_pos, origin: p.start, launch: p.launch, transport: @transport) }
            p.asleep = false
          end
          read_while_asleep(p, wake - offset)
          frames -= wake - offset
          offset = wake
        end

        # A mute ramp ending in this buffer: the graph stops on the ramp's
        # last frame (not the end of the buffer), so free-running
        # oscillators sleep at the same point whatever the buffer size
        asleep_after = 0
        if p.strip_ramp && p.strip_ramp.to <= 0 && !sidechained
          silent_from = p.strip_ramp.start + p.strip_ramp.length
          if silent_from <= base + offset
            p.strip_level = 0.0
            p.strip_ramp = nil
            p.asleep = true
            fade_ramp(p, base + offset, frames)
            read_while_asleep(p, frames)
            p.read_to = base + offset + frames
            return finish_player(p, false, base + offset + frames)
          end
          if silent_from < base + offset + frames
            asleep_after = base + offset + frames - silent_from
            frames -= asleep_after
          end
        end

        routed = @routed_span
        # A ringing tail is read in pieces that end where its quiet stretch
        # would: it sleeps having rendered exactly to that sample, so a
        # revived graph (a scene relaunching the track) continues from the
        # same state at any buffer size (omnibus13: kits revived after a
        # ring-out differed by buffer size, SessionFuzz seed 1194)
        quiet = ringing && p.ring.stop_frame ? p.ring.quiet : nil
        total = frames
        while true # (not loop do: its break and return allocated an imemo per player per buffer)
          frames = total
          if quiet
            ending = quiet.ends_at - base
            if ending <= offset
              note_rung_out(p, base + offset, rate)
              return retire(p, keep: true)
            end
            frames = ending - offset if ending < offset + frames
          end
          last = frames == total

          begin_bus_read(offset, p.name) if routed
          # Knob readers and MIDI input taps in the graph read from this
          # player's first frame (see GraphNode::Knob#clock_frame and
          # #player_frame)
          t = MB::U.clock_now
          gc = GC.stat(:time)
          begin
            @knob_frame = base + offset if @knob_frame
            @player_frame = base + offset
            data = p.input.read(frames)
          ensure
            @knob_frame = base if @knob_frame
            @player_frame = nil
          end
          elapsed = MB::U.clock_now - t
          p.cpu = (p.cpu || 0.0) + elapsed if @ui_feed
          check_speed(p, Session.without_gc(elapsed, gc), frames)
          read_while_asleep(p, asleep_after) if last # the rest of the buffer after a mute ramp
          p.read_to = base + offset + frames + (last ? asleep_after : 0)

          if data.nil? || data.empty? || data.all? { |d| d.nil? || d.empty? }
            retire(p)
            return
          end

          # A ringing tail stops on the sample where it has been quiet long
          # enough, or fades out once it has rung too long
          rung_out = false
          if quiet
            cap_ring(p, base + offset + frames, rate)
            keep = follow_ring(p, data, base + offset, frames, rate)
            if keep < frames || quiet.ends_at <= base + offset + frames
              rung_out = true
              frames = keep
              if frames == 0
                note_rung_out(p, base + offset, rate)
                return retire(p, keep: true)
              end
            end
          end

          # The strip (contract K7): fade, then level (Faders), then
          # mute/solo; readers hear it before the mute (+fade:+ below)
          fade = fade_ramp(p, base + offset, frames)
          level = fader_levels(p, base + offset, frames)
          fade = fade ? (level ? fade * level : fade) : level
          strip = ramp_levels(p, :strip_level, :strip_ramp, base + offset, frames)
          ramp = fade ? (strip ? fade * strip : fade) : strip
          # The route: CUE gets its share, MAIN the rest (see Cue)
          ramp = cue_route(p, data, ramp, offset, frames, base + offset) if p.cue

          if routed
            deliver_player(p, data, ramp, mix, stem, offset, frames, fade: fade)
          else
            c = -1
            while (c += 1) < mix.length # (no each_with_index: an imemo per player per buffer)
              m = mix[c]
              d = data[c % data.length]
              next if d.nil? || d.empty?
              d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
              len = MB::M.min(d.length, frames)
              # (FastArithmetic.add_at: the same float steps without views)
              next if FastArithmetic.add_at(m, offset, d, len, ramp)
              d = d[0...len]
              d = d * ramp[0...len] if ramp
              m[offset...(offset + len)] = m[offset...(offset + len)] + d
            end
          end

          if rung_out
            note_rung_out(p, base + offset + frames, rate)
            return retire(p, keep: true)
          end

          # A short read means the graph ended
          ended = data.any? { |d| d.nil? || d.length < frames }
          if last || ended
            finish_player(p, ended, base + offset + frames, to: to)
            break
          end
          offset += frames
          total -= frames
        end

      rescue => e
        p.read_to = nil # not kept in step (see Strip#read_kept_graphs)
        retire(p)
        raise if @raise_errors
        warn "Player #{p.name.inspect} (#{p.description}) stopped with an error: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
      end

      # Aligns the grids of the Synths in player +p+'s graph with the
      # Session's frames (see Synth#align_grid), +frame+ being the player's
      # first frame.
      def align_grids(p, frame)
        synths =
          if p.input.respond_to?(:synths)
            p.input.synths
          else
            nodes = p.input.respond_to?(:nodes) ? p.input.nodes : []
            nodes.flat_map { |n| n.respond_to?(:graph) ? [n, *n.graph] : [n] }.uniq.grep(Synth)
          end
        synths.each do |n|
          n.exact_lanes = true if @exact_lanes
          n.align_grid(frame)
        end
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
        elsif p.strip_level <= 0 && p.strip_ramp.nil? && !(@routed_span && bus_source?(p.name))
          p.asleep = true
        end
      end

      NO_TAPS = [].freeze

      # Calls each #add_tap block with the mix, removing blocks that raise.
      def call_taps(mix)
        # (a reused copy, taken under the lock: no Array a buffer)
        taps = @mutex.synchronize { @taps.empty? ? NO_TAPS : (@taps_copy ||= []).replace(@taps) }
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
        return unless @realtime && !p.slow_warned && Session.speed_warnings

        load = sustained_load(p, elapsed, frames)
        if load
          p.slow_warned = true
          warn "Player #{p.name.inspect} (#{p.description}) is taking #{(100 * load).round}% of its audio buffer time; it may cause dropouts"
        end
      end

      # +elapsed+ seconds minus the garbage collection since GC.stat(:time)
      # was +gc+ (ms): the slow-player warnings judge a player by its own
      # work.  A GC pause lands in whichever player allocates when it
      # starts (ux-fix-1 item 21: one 13-23 ms pause in a 16.7 ms buffer was
      # most of a 10-buffer average on the slower Mac), so it named players
      # that weren't slow.
      def self.without_gc(elapsed, gc)
        [elapsed - (GC.stat(:time) - gc) / 1000.0, 0.0].max
      end

      # The render thread's Ruby priority (the highest): a thread at
      # priority 0 gives up the GVL at a timer tick (every 10 ms with
      # RUBY_THREAD_TIMESLICE=10) whenever another thread wants it, so
      # while the scheduler thread built the next scene, a tick landing
      # inside a player's read handed the GVL over for a whole slice
      # (ux-fix-2: drums reads of 0.7 ms CPU took 10.7 ms, named by the
      # slow-player warning on the slower Mac).  At 3 it keeps the GVL
      # through eight ticks of running, longer than any buffer's work (the
      # scheduler thread runs at Scheduler::THREAD_PRIORITY, -3).
      RENDER_THREAD_PRIORITY = 3

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
            if @paused
              n = buffer_size
              output.write(Array.new(output.channels) { Numo::SFloat.zeros(n) })
            else
              process_buffer
            end
          end
        rescue => e
          warn "Background session stopped with an error: #{e.class}: #{e.message}"
        end
        @thread.name = 'MB::Sound::Session'
        @thread.priority = RENDER_THREAD_PRIORITY

        # Stop the thread and close the output cleanly at exit (held
        # weakly: an at_exit block would keep this Session and every graph
        # it played alive until exit)
        ExitClose.register(self)
      end

      # The bar number (counting from 1) of a timeline position.
      def bar_of(position)
        @transport.bar_at(position).floor
      end
    end
  end
end
