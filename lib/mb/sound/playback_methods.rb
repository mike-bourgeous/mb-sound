module MB
  module Sound
    # Command-line interface methods for playing sounds.  MB::Sound extends
    # itself with this module.
    module PlaybackMethods
      # Plays a sound file if a String is given, a generated tone if a Tone is
      # given, or an audio buffer if an audio buffer is given.  If an audio
      # buffer or tone is given, the sample rate should be specified (defaults to
      # 48k).  The sample rate is ignored for an audio filename.
      #
      # If +spectrum+ is true, then each chunk of audio plotted is shown in the
      # frequency domain instead of the time domain.
      #
      # If the PLOT environment variable is set to '0', then plotting defaults
      # to false.  Otherwise, plotting defaults to true.
      #
      # +:clear+ - Whether to clear the screen before beginning playback.
      def play(file_tone_data, output: nil, sample_rate: 48000, gain: 1.0, plot: nil, graphical: false, spectrum: false, device: nil, clear: true, quiet: false)
        # The monitor trim (see #monitor_gain) applies to the live output,
        # not to an output given by the caller
        trim = output.nil? ? Session.monitor_gain : 1.0

        clear_esc = clear ? "\e[H\e[J" : ''
        header = MB::U.wrap("#{clear_esc}\e[36mPlaying\e[0m #{playback_info(file_tone_data)}".lines.map(&:strip).join(' ') + "\n")
        # Oscillators play forever, so graphs usually play until interrupted
        header += "\e[33mPress Ctrl-C to stop\e[0m\n" if graph_playback?(file_tone_data)
        header += "\n"
        $stderr.puts header unless quiet

        plot = false if quiet && plot.nil?
        plot = false if ENV['PLOT'] == '0' && plot.nil?
        plot = { header_lines: header.lines.count, graphical: graphical } if plot.nil? || plot == true
        plot[:spectrum] = spectrum if plot.is_a?(Hash) && !plot.include?(:spectrum)

        if file_tone_data.is_a?(Numo::NArray) || (file_tone_data.is_a?(MB::Sound::GraphNode) && !file_tone_data.respond_to?(:read)) ||
            file_tone_data.is_a?(MB::Sound::GraphNode::MultiOutput)
          file_tone_data = [file_tone_data]
        end

        # Expand multi-output nodes (e.g. stereo bundles) into their channels
        if file_tone_data.is_a?(Array) && !file_tone_data.empty? && file_tone_data.all? { |d| d.is_a?(GraphNode) || d.is_a?(GraphNode::MultiOutput) }
          file_tone_data = file_tone_data.flat_map(&:outputs)
        end

        case file_tone_data
        when String
          return play_file(file_tone_data, gain: gain * trim, plot: plot, device: device, output: output)

        when IOInput, InputBufferWrapper
          return play_input(file_tone_data, gain: gain * trim, plot: plot, device: device, output: output)

        when Array
          if !file_tone_data.empty? && file_tone_data.all?(GraphNode)
            bufsize = file_tone_data.map(&:graph_buffer_size).compact.min # nil is ok here

            output ||= MB::Sound.output(
              sample_rate: sample_rate,
              channels: MB::M.max(2, file_tone_data.length),
              plot: plot,
              device: device,
              buffer_size: bufsize
            )

            # The output may run at another rate than asked for
            nodes = file_tone_data.map { |d|
              if d.sample_rate != output.sample_rate
                d.resample(output.sample_rate)
              else
                d
              end
            }

            input = nodes.as_input(output.channels)

            gain = master_gain * trim
            loop do
              buf = input.read(output.buffer_size)
              break if buf.nil? || buf.empty? || buf.any? { |d| d.nil? || d.empty? }

              output.write(Session.monitor_clip(buf.map { |c| c * gain }, trim).first)
            end

          else
            data = Internal.any_sound_to_array(file_tone_data).map { |c| c * (master_gain * trim) }
            data = Session.monitor_clip(data, trim).first
            data = data * 2 if data.length < 2
            channels = data.length

            output ||= MB::Sound.output(sample_rate: sample_rate, channels: channels, plot: plot, device: device)
            buffer_size = output.buffer_size

            # TODO: if this code needs to be modified much in the future, come up
            # with a shared way of chunking data that can work for all play,
            # write, and plot methods.  Maybe convert everything to signal nodes?
            #
            # TODO: maybe use ArrayInput
            (0...data[0].length).step(buffer_size).each do |offset|
              output.write(data.map { |c|
                MB::M.zpad(c[offset...([offset + buffer_size, c.length].min)], buffer_size)
              })
            end
          end

        else
          raise "Unsupported type #{file_tone_data.class.name} for playback"

        end

        $stderr.puts "\n\n" unless quiet
      end

      # True if +data+ given to #play is a node graph (which may never end,
      # since oscillators play forever) rather than a file or audio buffer.
      private def graph_playback?(data)
        data = [data] unless data.is_a?(Array)
        !data.empty? && data.all? { |d| d.is_a?(GraphNode) || d.is_a?(GraphNode::MultiOutput) } &&
          !data.any? { |d| d.respond_to?(:read) }
      end

      # The longest #render will run when neither +:bars+ nor +:seconds+ is
      # given and the sounds never end (+:max_seconds+ overrides it).
      MAX_RENDER_SECONDS = 600

      # Plays a sound in the background and returns its player name for
      # #stop.  The prompt stays available, so you can keep working while it
      # plays (e.g. change #bpm or start more sounds).
      #
      # Give a Symbol +name+ first to play in a named slot.  Running #bg again
      # with the same name replaces the old sound in sync when the new one
      # starts, so you can edit a line and re-run it to iterate.  Without a
      # name, the sound gets the lowest unused number.
      #
      # New sounds fade in over half a bar by default; pass +:fade+ to choose
      # the number of bars, or 0 for no fade.  Replacing a named sound
      # switches over without a fade unless +:fade+ is given, in which case
      # it crossfades.  Change the defaults with Session.default.fade_in= and
      # fade_out= (in bars).
      #
      # Accepts a GraphNode, an Array of GraphNodes (one per channel), or a
      # sound filename.  Everything played with #bg is mixed in one shared
      # Session, locked to one timeline, so sequences stay in sync.  If
      # something is already playing, the new sound starts on the next bar;
      # pass +:on+ to align it elsewhere (:now, :beat, :bar, :clip, a number
      # of bars, or a note length grid like 1.n4), +:in+ to start it that
      # long from now (bars or a Duration), or +:at+ for a position on the
      # timeline (e.g. bar(9)); see LaunchPoint.
      #
      # Errors during playback are printed and remove only the sound that
      # failed.
      #
      # Returns the change's journal entry (see Session::Journal), which
      # prints where it lands (e.g. `bg :bass lands 9:1 (queued)`) and gives
      # the player name as +name+ (#stop and the other commands accept it in
      # place of the name).  Inside a scheduled block, returns the name.
      # Every command is one undo step (see #undo).
      #
      # Example (bin/sound.rb):
      #     bass = seq(C2, C2, rest, C3, C2, rest, As1, G1).n16.loop
      #     bg :bass, bass.tone.ramp.at(1).filter(:lowpass, cutoff: 250 + bass.env(0.001, 0.012, 0, 0.012) * 4000, quality: 4).softclip(0.1, 0.5)
      #     bg bass.transpose(12).tone.triangle.at(0.3) * bass.env    # player 1, joins on the next bar
      #     bpm 140
      #     stop       # stops the last one started (player 1)
      #     outro      # fades everything out over four bars
      #     panic      # stops everything right away
      #
      # +send:+ (bus name => level, e.g. `send: { verb: -12.db }`) and +to:+
      # (a bus for its main out) route a named player (see BusMethods).
      def bg(name_or_sound, sound = nil, at: nil, on: nil, in: nil, fade: nil, to: nil, send: nil)
        point = LaunchPoint.of(binding) or return nil
        name, sound = sound.nil? ? [nil, name_or_sound] : [name_or_sound, sound]
        raise ArgumentError, ':all is reserved for stop(:all)' if name == :all

        # A clip given to a track with a patch plays through the patch (see
        # ArrangementMethods#track)
        if name && (sound.is_a?(Sequence::Clip) || sound.is_a?(Sequence::Kit))
          session = Session.current
          if session.arrangement.tracks[name]
            return session.arrangement.play(name, sound, at: point, fade: fade) if point.given?

            time = Session.context&.[](:time)
            time = session.send(:launch_time, nil, []) if time.nil? && !session.arrangement.tracks[name].q
            return session.arrangement.play(name, sound, start_time: time, fade: fade)
          end
        end

        # Graph documents' knobs join the session (Session#add does this
        # too); those with a controller get live MIDI input
        if sound.is_a?(GraphNode) || sound.is_a?(GraphNode::MultiOutput) || (sound.is_a?(Array) && sound.all? { |s| s.is_a?(GraphNode) || s.is_a?(GraphNode::MultiOutput) })
          s = Session.current
          attach_knob_midi(s, s.adopt_knobs(sound))
        end

        session_command(name, label: "bg #{name.inspect}", kind: :bg) { |session, time|
          session.add(sound, at: point, name: name, fade: fade, start_time: point.given? ? nil : time, to: to || :keep, send: send)
        }
      end

      # Stops background players (see #bg): with no arguments, the most
      # recently started one; with names or numbers, those players; with
      # :all, every player (see also #outro and #panic).  Players fade out
      # over four bars by default; pass +:fade+ for a different number of
      # bars, or 0 to stop right away.  When nothing is left playing, the
      # timeline pauses where it is (see SequenceMethods#seek and #rewind).
      #
      # Stops land right away (or at a scheduled block's time) unless given
      # a launch point (see LaunchPoint): `stop :bass, on: :bar`, `stop
      # :bass, in: 2.beats`, `stop :all, at: bar(17)`.
      #
      # +ring: true+ rings the players out instead (as scenes do; see
      # Session::Tails): their clips stop sending notes and each keeps
      # playing until its tail is silent, e.g. `stop :bass, ring: true`.
      #
      # Returns the stop's journal entry (see #bg; e.g. `stop :bass lands
      # 9:1 (queued)`), an Array of entries for several players, or an
      # empty Array if nothing was playing.  Inside a scheduled block,
      # returns the names.
      def stop(*names, fade: nil, ring: false, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        names = names.map { |n| player_name(n) }
        session_command(names, label: "stop #{names.map(&:inspect).join(', ')}".strip, kind: :stop, all: true) { |session, time|
          time = session.send(:launch_time, point, [], default: nil) if point.given?
          if names.empty?
            [session.remove_last(fade: fade, time: time, ring: ring)].compact
          elsif names == [:all]
            session.remove(fade: fade, time: time, ring: ring)
          else
            session.remove(*names, fade: fade, time: time, ring: ring).tap { |stopped|
              names.each do |name|
                # An armed track's live monitor keeps playing (maintainer,
                # 2026-10-13: stop stops the clips; "Keep, but add hints")
                mon = name.is_a?(Symbol) && !names.include?(Arrangement::Recording.monitor_name(name)) && Arrangement::Recording.monitor_name(name)
                if mon && session.playing_after_queue?(mon)
                  warn "stop #{name.inspect}: its live monitor #{mon.inspect} is still playing (disarm #{name.inspect} or stop #{mon.inspect})"
                elsif !stopped.include?(name)
                  warn "No background player #{name.inspect} is playing"
                end
              end
            }
          end
        }
      end

      # Ends everything playing in the background, fading out over four bars
      # by default (+:fade+ sets the number of bars), starting now or at a
      # launch point (`outro on: 4`, `outro at: bar(33)`).  Also available as
      # #fadeout.  Returns the journal entries, as #stop.  See #stop, and
      # #panic to stop everything right away.
      def outro(fade: nil, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        stop(:all, fade: fade, at: point)
      end
      alias fadeout outro

      # Stops every background player immediately, with no fade, including
      # players that are fading out or waiting to start.  The master effects
      # (see #master) stay, but their reverb and delay tails are cleared.
      # Audio already sent to the sound card may play for a moment longer.
      #
      # Panic also stops what would start things again: changes still
      # waiting to land (players waiting to start, scene launches, swaps,
      # mutes, ...) are cancelled, and the scheduler is reset (see
      # ScheduleMethods#reset_scheduler: the song form stops, every
      # scheduled block is cancelled, and a stuck or dead scheduler thread
      # is replaced).  It always prints one line saying what it stopped and
      # cancelled.
      #
      # Returns the journal entries of the stops and of the cancelled
      # changes (one entry, or an Array; see #stop).
      def panic
        cancelled = []
        message = nil
        stops = session_command([], label: 'panic', kind: :stop, all: true) { |session, time|
          report = session.reset_scheduler
          message = Session::Scheduler.reset_message(report)

          waiting = session.queued.reject { |e| time && e.lands&.pos && e.lands.pos < time }
          cancelled = session.cancel_changes(*waiting.map(&:seq)) unless waiting.empty?

          session.remove(fade: 0, time: time).tap { session.reset_master(time: time); session.reset_buses(time: time) }
        }
        return stops if Session.context&.[](:batch)

        stopped = Array(stops).grep(Session::Journal::Entry)
        warn "panic: #{panic_summary(stopped.length, cancelled.length, message)}"

        entries = [*stopped, *cancelled]
        entries.length == 1 ? entries.first : entries
      end

      # The one line #panic prints: players stopped, changes cancelled, and
      # what resetting the scheduler did (+scheduler+, or nil).
      private def panic_summary(stopped, cancelled, scheduler)
        parts = ["stopped #{stopped} player#{'s' unless stopped == 1}"]
        parts << "cancelled #{cancelled} queued change#{'s' unless cancelled == 1}" if cancelled > 0
        parts << scheduler if scheduler
        parts.join('; ')
      end

      # Plays background sounds (#bg, songs) through +output+ from now on:
      # an output object (anything with #write, #sample_rate, #buffer_size,
      # and #close, e.g. an FFMPEGOutput streaming to a URL), an output type
      # Symbol for MB::Sound.output (e.g. :device, :ffmpeg, :null), or nil
      # to go back to the automatic output.  The background session restarts
      # with the new output (master effects too), so stop all players first.
      # Returns the new output (nil for the automatic one).
      #
      # Example (bin/sound.rb):
      #     use_output :device
      #     use_output FFMPEGOutput.new('udp://127.0.0.1:1234', format: 'mpegts', codec: 'aac', sample_rate: 48000, channels: 2, realtime: true)
      #     use_output nil
      def use_output(output = nil)
        if output.is_a?(Symbol)
          output = MB::Sound.output(output_type: output, channels: 2, shared: false)
        end

        switch_output(output)
        output
      end

      # With a +profile+ (:low, :default, :video, or :safe; see
      # DeviceOutput::PROFILES), plays background sounds through the sound
      # card with that latency from now on: the background session restarts
      # with a new output (see #use_output), so stop all players first.
      # Light patches (e.g. a few band-limited oscillators) can use :low;
      # heavy graphs need :default or :safe.  An AUDIO_PROFILE environment
      # variable still takes precedence.  Without a profile, returns the
      # current output's profile (nil if it has none).  Also available as
      # #lag.
      #
      # Example (bin/sound.rb):
      #     latency :low     # about 16-19 ms on the user's Mac
      #     lag :default     # about 45-56 ms
      #     latency          # => :default
      def latency(profile = nil)
        if profile.nil?
          out = Session.default.output
          return out.respond_to?(:profile) ? out.profile : nil
        end

        type = Internal.detect_output == :null ? :null : :device
        use_output(MB::Sound.output(output_type: type, channels: 2, shared: false, profile: profile))
        profile.to_s.delete_prefix(':').to_sym
      end
      alias lag latency

      # Switches the background session to the sound card's :low latency
      # profile for live MIDI (about 18 ms from key to sound with exact MIDI
      # timing instead of about 63 ms; see MIDI::LiveSource).  Called when
      # live MIDI input opens (#midi, synth scripts, effect scripts' MIDI
      # controls); heavy patches still play, since the adaptive output
      # queue grows after dropouts (see DeviceOutput).
      #
      # Does nothing (returns nil) when a profile was chosen: AUDIO_PROFILE
      # (which scripts' -L/--latency-profile and +profile:+ set), or an
      # output given to #latency or #use_output.  Also nothing for outputs
      # other than the sound card (OUTPUT_TYPE ffmpeg or null).  Prints a
      # hint instead of switching when the background session has players
      # or master effects (switching restarts the session).  Returns :low
      # when the session plays (or will play) through the :low profile.
      #
      # Example (bin/sound.rb; #midi calls it):
      #     live_midi_latency    # => :low
      def live_midi_latency(quiet: false)
        return nil if !ENV['AUDIO_PROFILE'].to_s.empty? || Session.output_chosen? || Internal.detect_output != :device

        session = Session.default
        if session.output_open?
          out = session.output
          return :low if out.respond_to?(:profile) && out.profile == :low

          unless session.idle? && session.master_info == 'bypass'
            warn 'Live MIDI: `latency :low` lowers the latency once players and master effects are stopped' unless quiet
            return nil
          end
        end

        switch_output(MB::Sound.output(output_type: :device, channels: 2, shared: false, profile: :low), chosen: false)
        warn 'Live MIDI: using the :low latency profile (-L, AUDIO_PROFILE, or `latency` choose another)' unless quiet
        :low
      end

      # Sets master effects that the whole background mix (see #bg) runs
      # through, e.g. to tame levels or add a shared reverb.  The block gets
      # the mix and returns the processed mix.  Also available as
      # #master_fx.
      #
      # A block with one parameter gets the whole mix as a stereo bundle
      # (GraphNode::Channels): most methods run on each channel (e.g.
      # `mix.softclip`), and #reverb takes both channels as inputs.  A block
      # with one parameter per channel (`|l, r|`) gets them separately.
      # Return a bundle, an Array of nodes (one per channel), or one node for
      # every channel.  Call with nil (or false) to remove the effects, and
      # with no arguments to see what is set.
      #
      # Like #bg, new effects start on the next bar while anything is
      # playing (+:on+, +:in+, or +:at+ picks another launch point; see #bg).  By default the old
      # effects get no more sound from that point but finish what they were
      # doing, so reverb and delay tails ring out ("spillover").  Pass
      # +:fade+ to crossfade over a number of bars instead, or 0 to cut over.
      # Master effects keep processing while nothing is playing, so tails
      # ring out at the end, and #render adds up to ten seconds of tail
      # after the last player stops.
      #
      # Example (bin/sound.rb):
      #     master { |mix| mix.softclip(0.5, 0.95) }
      #     master { |mix| mix.filter(:highpass, cutoff: 30).reverb(:room).softclip(0.5, 0.95) }
      #     master { |l, r| [l, r.delay(0.012)] }   # Haas widening
      #     master          # shows the current effects
      #     master nil      # removes them on the next bar
      def master(effects = :show, at: nil, on: nil, in: nil, fade: nil, &block)
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        if block.nil? && effects == :show
          return session.master_info
        elsif !block.nil? && effects != :show
          raise ArgumentError, 'Pass a block for master effects, or nil to remove them, not both'
        elsif block.nil? && effects
          raise ArgumentError, "Pass a block for master effects, or nil to remove them (got #{effects.inspect})"
        end

        session_command(nil, label: block ? 'master' : 'master nil', kind: :master) { |s, time|
          s.master(at: point, fade: fade, start_time: point.given? ? nil : time, &block)
        }
      end
      alias master_fx master

      # Returns the master bus gain of the current session (linear, -10 dB by
      # default), applied to the whole mix live and in renders alike
      # (renders start with the current session's gain and placement, or
      # pass +gain:+ to #render).  With a +gain+, changes it first.
      #
      # The gain applies before the master effects (see #master) by default,
      # so a limiter or clipper there keeps its ceiling whatever the gain.
      # +post: true+ moves it after them (the placement before 2026-10-13;
      # like a DAW's pre/post-fader switch for master inserts), +post: false+
      # back; the placement stays until changed.  Without master effects
      # both give the same samples.
      #
      # Example (bin/sound.rb):
      #     master_gain -6.db
      #     master_gain.to_db   # => -6.0
      #     master_gain 2.db, post: true   # after the master chain
      def master_gain(gain = nil, post: nil)
        session = Session.current
        session.master_gain = gain if gain
        session.master_gain_post = post unless post.nil?
        session.master_gain
      end

      # Sets the master bus gain of the current session (see #master_gain).
      def master_gain=(gain)
        master_gain(gain)
      end

      # Returns the monitor trim (linear, 1.0 = 0 dB): a listening gain for
      # live playback only, after the master chain, any limiter, and the
      # master gain, that never reaches #render, stems, #rec_audio files,
      # vis, or takes (see Session::MonitorTrim).  With a +gain+ (linear,
      # up to +27 dB), sets it first.  The listening level check
      # (`help.level`) sets it too.  Peaks the trim pushes over full scale
      # are clipped on the way out, with a warning.  Also available as
      # #monitor.
      #
      # Example (bin/sound.rb):
      #     monitor_gain 6.db       # louder in the speakers, renders unchanged
      #     monitor_gain.to_db      # => 6.0
      #     monitor 0.db
      def monitor_gain(gain = nil)
        Session.monitor_gain = gain if gain
        Session.monitor_gain
      end
      alias monitor monitor_gain

      # Changes the sequence a background player (see #bg) plays, keeping
      # its synth and effects as they are, e.g. to try a new bass line
      # through the same filter and reverb.  Like #bg, the change happens
      # on the next bar (+:on+, +:in+, or +:at+ picks another launch point;
      # see #bg), exactly on the
      # sample.  Returns the change's journal entry (see #bg).
      #
      # Pass the new clip to replace the clip that every clip in the graph
      # was made from, or old => new pairs to choose.  Clips made from the
      # old clip (e.g. bass.transpose(12), or the voices of Clip#synth) are
      # rebuilt from the new one the same way.  Stopped players can be
      # swapped too, and play the new clip when resumed.  See Session#swap.
      #
      # Example (bin/sound.rb):
      #     bass = seq(C2, C2, rest, C3).n16.loop
      #     bg :bass, bass.tone.ramp.at(1).filter(:lowpass, cutoff: 400 + bass.env * 3000, quality: 4) * bass.env
      #     swap :bass, seq(C2, Eb2, G2, Bb2).n16.loop
      #     swap :bass, bass                         # back to the first bass line
      #
      #     beat = grid(16, kick: 'x...x...', snare: '....x...')
      #     beat2 = grid(16, kick: 'x..x..x.', snare: '....x..x')
      #     swap :drums, beat => beat2               # swaps each matching row
      def swap(name, clips = nil, at: nil, on: nil, in: nil, **pairs)
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, 'Pass a new clip or old => new pairs, not both' if clips && !pairs.empty?
        clips ||= pairs
        raise ArgumentError, 'Pass a new clip or old => new pairs to swap' if clips.is_a?(Hash) && clips.empty?

        name = player_name(name)
        session_command(name, label: "swap #{name.inspect}", kind: :swap) { |session, time|
          session.swap(name, clips, at: point, start_time: point.given? ? nil : time)
          name
        }
      end

      # Brings back a named background player that was stopped (see #bg and
      # #stop), unchanged, e.g. to fade a track back in.  With no name,
      # resumes the most recently stopped player.  Like #bg, it starts on the
      # next bar and fades in over half a bar by default (+:on+, +:in+,
      # +:at+, and +:fade+ work the same way).  Returns the change's journal entry (see #bg),
      # or nil if there was nothing to resume.
      #
      # Only players with Symbol names are kept after stopping; see
      # #stopped and #forget.
      #
      # Example (bin/sound.rb):
      #     bg :pad, pad_graph
      #     stop :pad      # fades out over four bars
      #     resume :pad    # fades the same graph back in on the next bar
      def resume(name = nil, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        name = player_name(name)
        session_command(name, label: "resume #{name.inspect}", kind: :resume) { |session, time|
          session.resume(name, at: point, fade: fade, start_time: point.given? ? nil : time).tap { |resumed|
            if resumed.nil?
              what = name ? "#{name.inspect} (not stopped, or already playing)" : '(nothing has been stopped)'
              warn "No background player to resume #{what}"
            end
          }
        }
      end

      # Returns a Hash from name to description of stopped background
      # players that can be resumed (see #resume).
      def stopped
        Session.current.stopped
      end

      # Discards stopped background players so they can't be resumed (all of
      # them if no names are given); undoable (see #undo).  Returns the
      # journal entry (an Array for several, empty if nothing was stopped),
      # like #stop.
      def forget(*names)
        names = names.map { |n| player_name(n) }
        session_command(names, label: "forget #{names.map(&:inspect).join(', ')}".strip, kind: :forget, all: true) { |session, time|
          session.forget(*names, time: time)
        }
      end

      # Plots the background mix (see #bg) live until you press Ctrl-C, then
      # returns to the prompt while playback continues.  Each frame plots
      # the newest buffer of the mix with level meters, as fast as the
      # plotter can draw; buffers that arrive while a frame is drawing are
      # skipped.  Also available as #vis.
      #
      # +:graphical+ plots inline images (iTerm2, kitty, sixel) instead of
      # text, and +:spectrum+ plots the frequency spectrum (log frequency
      # with note names) instead of the waveform.
      #
      # The mix is rendered a little ahead of what you hear (by the output's
      # buffering), so the plot may lead the sound slightly.
      #
      # +:stop+ is an optional callable checked about every 50 ms; plotting
      # ends when it returns true (e.g. when a script's #wait has returned,
      # so `--plot` doesn't keep a finished script running).
      #
      # Returns a Hash with the number of frames drawn and the frame rate.
      def visualize(graphical: false, spectrum: false, stop: nil)
        session = Session.default
        unless session.running?
          warn 'Nothing is playing in the background; start something with bg first'
          return nil
        end

        # Each buffer is shown when it reaches the speakers: the tap runs
        # right after a buffer is written, so it plays after the output's
        # current latency (DeviceOutput#latency; outputs without one are
        # shown right away)
        output = session.output
        due = []
        due_lock = Mutex.new
        tap = session.add_tap { |mix|
          delay = output.respond_to?(:latency) ? output.latency : 0
          due_lock.synchronize {
            due << [MB::U.clock_now + delay, mix]
            due.shift while due.length > 1000
          }
        }
        latest = nil

        header = "\e[H\e[J\e[36mVisualizing the background mix\e[0m\n\n"
        $stdout.write header
        plot_output = PlotOutput.new(
          session.output,
          plot: plotter(graphical: graphical),
          graphical: graphical,
          spectrum: spectrum,
          header_lines: header.lines.count,
          window_size: 1 << 20 # plot the whole buffer, whatever its size
        )

        frames = 0
        start = MB::U.clock_now
        shown = nil
        next_check = start
        loop do
          now = MB::U.clock_now
          if stop && now >= next_check
            break if stop.call
            next_check = now + 0.05
          end

          due_lock.synchronize {
            latest = due.shift[1] while due.first && due.first[0] <= now
          }

          data = latest
          if data.nil? || data.equal?(shown)
            sleep 0.001
            next
          end

          shown = data
          plot_output.plot(data)
          frames += 1
        end

        visualize_result(start, frames)

      rescue Interrupt
        visualize_result(start, frames)

      ensure
        session.remove_tap(tap) if tap
      end
      alias vis visualize

      # Waits until everything playing in the background (see #bg) has ended,
      # including master effects tails: nothing is playing or waiting to
      # start, and the mix has been quiet for Session::TAIL_QUIET_SECONDS
      # (after at most Session::MAX_TAIL_SECONDS of tail).  Returns true, or
      # false if +:timeout+ seconds pass first.  Returns right away if the
      # background session isn't running.
      #
      # Use it at the end of scripts so they don't exit (and cut off reverb
      # tails) while the song is still ringing:
      #
      #     my_song
      #     wait
      def wait(timeout: nil)
        raise 'Cannot wait inside a scheduled block (it would block the scheduler)' if Session.context&.[](:batch)

        session = Session.current
        return true unless session.running?

        rate = session.output.sample_rate
        quiet = 0
        tail = 0
        tap = session.add_tap { |mix|
          if session.idle? && !session.schedule_due?
            tail += mix[0].length
            quiet = session.quiet?(mix) ? quiet + mix[0].length : 0
          else
            tail = quiet = 0
          end
        }

        deadline = timeout && MB::U.clock_now + timeout
        until quiet >= Session::TAIL_QUIET_SECONDS * rate || tail >= Session::MAX_TAIL_SECONDS * rate
          return false if deadline && MB::U.clock_now > deadline
          return true unless session.running?
          sleep 0.05
        end

        true
      ensure
        session&.remove_tap(tap) if tap
      end

      # Returns a Hash from background player name (see #bg) to a
      # description of what it is playing.
      def players
        Session.current.players
      end

      # Renders +sounds+ (GraphNodes, Arrays of GraphNodes, or filenames) to
      # an audio file as fast as possible.  All sounds start together at the
      # beginning of a fresh timeline, at the current tempo unless +:bpm+ is
      # given.  Rendering stops after +:bars+ (counted on the timeline, so
      # tempo changes during the render are followed) or +:seconds+, or when
      # every sound has ended.  Returns the number of seconds rendered.
      #
      # A +:bars+ render always reaches its end bar (plus the tail, below),
      # however long that takes (a song form that loops back renders until
      # it gets there).  Only renders without +:bars+ or +:seconds+ stop at
      # MAX_RENDER_SECONDS (ten minutes, with a warning) if their sounds
      # never end.  +:max_seconds+ caps any render explicitly, tail
      # included, without a warning (for renders without a length it
      # replaces MAX_RENDER_SECONDS).
      #
      # If a block is given, it runs first with the rendering session as the
      # current session, so #bg, #at_bar, #every, #bpm, etc. inside it
      # arrange a song on the file's timeline (see ScheduleMethods).
      #
      #     render 'song.flac', bars: 32 do
      #       bg :pad, pad_graph
      #       at_bar(9) { bg :drums, drum_graph }
      #       at_bar(25) { outro }
      #     end
      #
      # If master effects are set inside the block (see #master), up to ten
      # seconds of their tail are added after the last sound stops, until a
      # second of silence (within the +:bars+ or +:seconds+ limit, if given).
      # With +tail: true+, the tail is also added after the +:bars+ or
      # +:seconds+ limit: any sounds still playing stop there, and the
      # master effects ring out, e.g. `render('song.flac', bars: 16, tail:
      # true) { my_song }`.
      #
      # Build fresh graphs to render, rather than rendering graphs that are
      # playing in the background, because graphs keep their playback state.
      #
      # Instead of a filename, +filename+ may be an output object (anything
      # with #write, #sample_rate, and #close, e.g. an FFMPEGOutput with
      # realtime: true streaming to a URL); it is closed when the render
      # finishes.
      #
      # With +:loudness+ (a number of LUFS or a Loudness::TARGETS name like
      # :spotify or :ebu_r128; see Loudness.target), the finished file is
      # normalized in a second pass: measured per ITU-R BS.1770 and
      # rewritten with the gain that reaches the target (see
      # Loudness.normalize_file; gain only, no limiter).  +:peak+ says what
      # to do when that gain would put the true peak above the target's
      # ceiling: :warn (default) keeps the loudness and warns, :reduce lowers
      # the gain to the ceiling (missing the loudness target, with a
      # warning).  Needs a filename (not an output object).  The master
      # gain still applies while rendering, so it doesn't change the result
      # (except for clipping in integer formats, which the second pass
      # can't undo: leave headroom, as the default -10 dB master gain does).
      #
      # With +:stems+ (a directory), each player (track) is also written to
      # its own file there, "<name>.<ext>" (+:stem_format+, else the
      # extension of +filename+, e.g. 'mp3'): its part of the mix as it
      # enters the master chain, times the master gain, from the first frame
      # and padded to the length of the render, so stems line up sample for
      # sample.  Without master effects they sum to the mix; with them, to
      # the mix before the chain (see Session::Stems).  +:stem_gain+ scales
      # every stem (headroom: before a master limiter a part may peak above
      # full scale, which integer formats clip; the render warns).
      # A track that sends or plays into buses (see BusMethods) carries its
      # own share of each bus in its stem (its own copy of every bus it
      # reaches, fed only by it), so stems still sum to the mix before the
      # master chain; +:bus_stems+ (true) also writes each bus's output as
      # "<bus>.<ext>".  +:loudness+ normalizes only the mix file.
      #
      # +:exact_lanes+ (true) makes the render the same at any buffer size
      # where Synths free lanes for new notes (see Synth#exact_lanes?; costs
      # CPU at buffer sizes other than 800).
      #
      #     render('song.flac', bars: 32, stems: 'song_stems') { my_song }
      #
      # Example (bin/sound.rb):
      #     bass = seq(C2, C2, rest, C3).n16.loop
      #     render '/tmp/bass.flac', bass.tone.ramp.at(1) * bass.env * 0.5, bars: 4
      #     render '/tmp/bass_spotify.flac', bass.tone.ramp.at(1) * bass.env, bars: 4, loudness: :spotify
      def render(filename, *sounds, loudness: nil, peak: :warn, **kwargs, &block)
        return render_session(filename, *sounds, **kwargs, &block) unless loudness

        raise ArgumentError, 'render(loudness:) needs a filename to normalize (not an output object)' unless filename.is_a?(String)
        target = Loudness.target(loudness)
        seconds = render_session(filename, *sounds, **kwargs, &block)
        Loudness.normalize_file(filename, target, peak: peak)
        seconds
      end

      private

      # The frame count and rate returned by #visualize.
      def visualize_result(start, frames)
        elapsed = MB::U.clock_now - start if start
        { frames: frames || 0, fps: elapsed && elapsed > 0 ? ((frames || 0) / elapsed).round(1) : 0 }
      end

      # Renders without normalization (see #render).
      def render_session(filename, *sounds, bars: nil, seconds: nil, tail: false, bpm: nil, channels: 2, overwrite: false, buffer_size: 800, gain: nil, stems: nil, stem_format: nil, stem_gain: 1.0, bus_stems: false, max_seconds: nil, exact_lanes: false, &block)
        raise ArgumentError, 'Pass one or more sounds or a block to render' if sounds.empty? && block.nil?
        raise ArgumentError, "max_seconds: must be positive (got #{max_seconds.inspect})" if max_seconds && max_seconds <= 0
        raise ArgumentError, 'Pass bars: or seconds:, not both' if bars && seconds

        current = Sequence.current_transport
        transport = Sequence::Transport.new(bpm: bpm || current.bpm, bar_length: current.bar_length)
        output = filename.respond_to?(:write) ? filename : file_output(filename, channels: channels, overwrite: overwrite)
        session = Session.new(output: output, transport: transport, master_gain: gain || master_gain, master_gain_post: Session.current.master_gain_post?, channels: channels, buffer_size: buffer_size, realtime: false, raise_errors: true)
        session.exact_lanes = exact_lanes
        if stems
          stem_format ||= filename.is_a?(String) && !File.extname(filename).empty? ? File.extname(filename) : 'flac'
          session.stems = Session::Stems::Writer.new(stems, format: stem_format, channels: channels, sample_rate: output.sample_rate, overwrite: overwrite, gain: stem_gain, buses: bus_stems)
        end

        rate = output.sample_rate
        bars = Sequence::Duration.bars(bars, transport.bar_length, transport: transport, sample_rate: rate)
        seconds = Length.seconds(seconds, sample_rate: rate, transport: transport) if seconds
        # The end bar's position through the meter map (read every buffer,
        # so meter changes made while rendering count)
        end_time = bars && -> { transport.bar_position(bars.to_r + 1) }
        # A bars: render has no time limit of its own (it ends at its end
        # bar plus the tail); the others stop at seconds: or
        # MAX_RENDER_SECONDS (maintainer decision 2026-10-13), and
        # max_seconds: caps any of them (replacing MAX_RENDER_SECONDS)
        max_frames =
          if seconds
            (seconds * rate).round
          elsif bars || max_seconds
            Float::INFINITY
          else
            (MAX_RENDER_SECONDS * rate).round
          end
        max_frames = MB::M.min(max_frames, (max_seconds * rate).round) if max_seconds

        sounds.each { |s| session.add(s, on: :now) }
        Session.with_context(session: session) { block.call } if block

        # Frames left to render: up to the end bar at the current tempo (so
        # tempo changes during the render count), or up to the time limit
        frames = 0
        frames_left = -> {
          left = max_frames - frames
          if end_time
            to_go = end_time.call - transport.position
            left = MB::M.min(left, to_go <= 0 ? 0 : (to_go / transport.whole_notes_per_second * rate).ceil)
          end
          left
        }

        until frames_left.call <= 0 || (session.idle? && !session.schedule_due?)
          count = MB::M.min(buffer_size, frames_left.call)
          session.process_buffer(count)
          frames += count
        end

        if frames_left.call > 0
          frames += render_tail(session, frames_left.call, buffer_size)
        elsif tail && (bars || seconds)
          # The song reached its end; stop anything still playing and let the
          # master effects ring out
          session.remove(fade: 0)
          # (up to Session::MAX_TAIL_SECONDS, or what max_seconds: leaves)
          frames += render_tail(session, max_seconds ? (max_seconds * rate).round - frames : Float::INFINITY, buffer_size)
        end

        if bars.nil? && seconds.nil? && max_seconds.nil? && !session.idle?
          warn "Stopped rendering #{filename} after #{MAX_RENDER_SECONDS} seconds; pass bars: or seconds: for sounds that never end"
        end

        frames.to_f / rate

      ensure
        session&.stems&.close(session.frame)
        session&.close
      end

      # Replaces the background session's output (see Session.use_output),
      # and points live MIDI sources opened by #midi at the new output's
      # clock (see MIDI::LiveSource#output=).
      def switch_output(output, chosen: true)
        Session.use_output(output, chosen: chosen)
        retarget_live_midi if respond_to?(:retarget_live_midi, true)
      end

      # Renders the tail of a session's master effects after the last player
      # stops (see #render), for up to +max_frames+.  Returns the number of
      # frames rendered.
      def render_tail(session, max_frames, buffer_size)
        return 0 unless session.master_active? || session.buses_awake?

        rate = session.output.sample_rate
        max_frames = MB::M.min(max_frames, (Session::MAX_TAIL_SECONDS * rate).round)
        quiet_frames = Session::TAIL_QUIET_SECONDS * rate

        frames = 0
        quiet = 0
        while frames < max_frames && quiet < quiet_frames
          count = MB::M.min(buffer_size, max_frames - frames)
          mix = session.process_buffer(count)
          frames += count
          quiet = session.quiet?(mix) ? quiet + count : 0
        end

        frames
      end

      # Runs a background playback command with the current session (see
      # Session.current) and the scheduled time, if any, as one undo step
      # labeled +label+ (see Session#command).  Inside a scheduled block
      # (see ScheduleMethods), the command is queued to take effect at the
      # block's time instead, and +result+ is returned.
      #
      # With a +kind+, returns the journal entry of the command's last
      # change of that kind (as it is now; see Session::Journal), or the
      # command's value if it made none.  With +all+, every entry of that
      # kind: one entry, or an Array for several.
      def session_command(result, label: nil, kind: nil, all: false, &command)
        context = Session.context
        session = Session.current
        time = context&.[](:time)

        if context&.[](:batch)
          context[:batch] << -> { command.call(session, time) }
          result
        else
          value, changes = session.command(label) { command.call(session, time) }
          return value if kind.nil? || value.nil?
          if all
            entries = (changes || []).select { |c| c.kind == kind }.map { |c| session.journal[c.seq] }
            return value if entries.empty?
            return entries.length == 1 ? entries.first : entries
          end
          changes&.reverse&.find { |c| c.kind == kind }&.then { |c| session.journal[c.seq] } || value
        end
      end

      # A player name given to a command: a Symbol or Integer, or a journal
      # entry returned by another command.
      def player_name(name)
        name.is_a?(Session::Journal::Entry) ? name.subject : name
      end

      # Plays the given filename using the default audio output returned by
      # MB::Sound.output.  The +:channels+ parameter may be used to force mono
      # playback (mono sound is converted to stereo by default), or to ask ffmpeg
      # to upmix or downmix audio to a different number of channels.
      def play_file(filename, channels: nil, gain: 1.0, plot: true, device: nil, output:)
        input = MB::Sound::FFMPEGInput.new(filename, channels: channels, resample: 48000)
        play_input(input, gain: gain, plot: plot, device: device, output: output)
      end

      # Plays the given audio input object (e.g. MB::Sound::FFMPEGInput) to
      # either a given output, or the system default output.
      def play_input(input, channels: nil, gain:, plot:, device:, output:)
        gain *= master_gain
        output ||= MB::Sound.output(channels: channels || (input.channels < 2 ? 2 : input.channels), plot: plot, device: device)

        buffer_size = output.buffer_size

        # TODO: Move all playback loops to a processing helper method when those are added
        loop do
          data = input.read(buffer_size)
          break if data.nil? || data.empty? || data[0].empty?

          # Apply gain and pad the final input chunk to the output buffer size
          data = data.map { |d|
            MB::M.zpad(d.inplace * gain, buffer_size).not_inplace!
          }

          # Ensure the output is at least stereo (Pulseaudio plays nothing for
          # mono output on my system)
          data = data * output.channels if data.length == 1 && output.channels > 1

          output.write(data)
        end

      ensure
        input&.close
      end

      # Returns a String with info to display when playing the given
      # +file_tone_data+.
      # The description of a graph for #playback_info: its last node's #to_s,
      # looking through wrapper nodes (TimeLimit, Ringdown; anything with
      # #wrapped_description) and Tee branches to the node they wrap, with
      # the wrapper's label after its name (e.g. "lp4/id=12 until 2 bars --
      # lp4(800.0 Hz, r=0.0)").
      def graph_description(node)
        node = node.owner_tee.original_source while node.is_a?(GraphNode::Tee::Branch) && node.owner_tee.original_source
        return node.to_s unless node.respond_to?(:wrapped_description)

        inner, label = node.wrapped_description
        head, sep, rest = graph_description(inner).partition(' -- ')
        "#{head} #{label}#{sep}#{rest}"
      end

      def playback_info(file_tone_data)
        case file_tone_data
        when Array
          file_tone_data.map { |ftd| playback_info(ftd) }

        when GraphNode
          filename = file_tone_data.graph.detect { |n| n.respond_to?(:filename) }&.filename
          filename || graph_description(file_tone_data)

        when String
          "\e[1m#{file_tone_data}\e[22m: #{MB::U.highlight(FFMPEGInput.parse_info(file_tone_data).dig(:format, :tags))}"

        else
          MB::U.highlight(file_tone_data)
        end
      end
    end
  end
end
