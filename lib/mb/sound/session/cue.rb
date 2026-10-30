require_relative 'cue_prefs'

module MB
  module Sound
    class Session
      # The CUE route (design/notes/cue.md): players heard in the phones in
      # time with the set before the audience hears them.  Each player's
      # strip ends in two gains, MAIN and CUE (Levels; nil for MAIN only,
      # the usual case): cue players (named :"x/cue") play at MAIN 0, CUE 1,
      # pre-listened players (#pfl) add CUE 1 to their MAIN, and #launch_cue
      # renames :"x/cue" to :x and crossfades it from CUE to MAIN on the
      # exact landing frame, so the same graph carries on.
      #
      # The cue mix is dry (post-strip, before buses and the master chain).
      # Each span it becomes the phones mix with the post-master MAIN mix,
      # through the Session knobs :phones (level) and :cue_mix (0 CUE only,
      # 1 MAIN only), and #process_buffer writes it where #cue_output says.
      # Renders, stems, recordings, and taps only see MAIN.
      module Cue
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # Where :cue_mix starts in new Sessions (0, CUE only, unless the
          # user saved another value; see Prefs and CueMethods#cue_mix).
          def cue_mix_default
            @cue_mix_default || 0.0
          end

          def cue_mix_default=(value)
            raise ArgumentError, "cue_mix must be from 0 to 1 (got #{value.inspect})" unless value.is_a?(Numeric) && value.real? && value >= 0 && value <= 1
            @cue_mix_default = value.to_f
          end
        end

        # Where CUE goes (see #cue_output=).
        OUTPUT_MODES = [:auto, :ports, :split, :phones, :off].freeze

        # Change kinds of the CUE route (undone through CueSubject).
        KINDS = [:cue, :uncue, :launch].freeze

        # A player's route gains: MAIN and CUE levels with their ramps
        # (Fades::Ramp, counted in session frames; nil when steady).
        Levels = Struct.new(:main_level, :main_ramp, :cue_level, :cue_ramp)

        # Undo subject of PFL and launch changes for player name +name+.
        CueSubject = Data.define(:name)

        # A name around a cue change, for undo: whether it was pre-listened
        # (+pfl+), the serial of its cue player (+cue_serial+, nil for
        # none), and its MAIN player's PlayerState (+main+).
        CueState = Struct.new(:pfl, :cue_serial, :main, keyword_init: true)

        # Where CUE goes: :auto (CUE on channels 3-4 when the output has
        # twice the Session's channels, else nowhere), :ports (those
        # channels), :split (2 channels: MAIN mono left, phones mono right),
        # :phones (2 channels: the phones mix on both), or :off.
        attr_reader :cue_output

        # Sets #cue_output (live: MB::Sound.live_error if the output can't
        # do it).
        def cue_output=(mode)
          mode = mode.to_s.delete_prefix(':').to_sym if mode.is_a?(String)
          unless OUTPUT_MODES.include?(mode)
            return MB::Sound.live_error(ArgumentError.new("cue_output takes #{OUTPUT_MODES.map(&:inspect).join(', ')} (got #{mode.inspect})"))
          end
          if output_open?
            need = mode == :ports ? @channels * 2 : nil
            if need && output_channel_count < need
              return MB::Sound.live_error(ArgumentError.new(
                "cue_output :ports needs a #{need}-channel output (this one has #{output_channel_count}); " \
                "start with CUE_OUTPUT=ports, or while idle `use_output output(channels: #{need}, cue: #{@channels})`; " \
                "on 2 channels try :split or :phones"
              ))
            end
          end
          @render_lock.synchronize { @cue_output = mode; @cue_warned = false }
          mode
        end

        # #cue_output as it applies to the open output (:auto resolved).
        # :auto never puts CUE into a file a render writes (omnibus17, Kez's
        # K14: a take replayed to a file, or any render with a `cue`, carried
        # the phones on its right channel from the cue's frame, :split).
        def cue_mode
          return @cue_output unless @cue_output == :auto
          return :off unless output_open?
          return :off if rendering_to_file?
          n = output_channel_count
          return :ports if n >= @channels * 2
          @cue_split_from && n == 2 ? :split : :off
        end

        # True if CUE reaches the phones without changing MAIN: its own
        # channels (:ports), or a 2-channel mode chosen or already engaged
        # (:split, :phones).  An :auto output of 2 channels that hasn't cued
        # anything yet is false: its first cue would put MAIN in mono on the
        # left (see #cue_output), which an audition shouldn't do.  The
        # library picker's auditions (LibraryMethods#audition) play on CUE
        # when this is true, else on MAIN.
        def cue_heard?
          %i[ports split phones].include?(cue_mode)
        end

        # The phones knobs [:phones, :cue_mix], made on first use (a knob
        # already defined under either name is used as it is).
        def cue_knobs
          @cue_knobs ||= [
            knobs[:phones] || knob(:phones, 1.0, range: 0.0..2.0),
            knobs[:cue_mix] || knob(:cue_mix, Session.cue_mix_default, range: 0.0..1.0),
          ]
        end

        # Plays +sound+ on CUE as player :"name/cue" (MAIN untouched); the
        # options are Session#add's, except that it starts right away unless
        # given a launch point (clips follow the timeline, so it is in time
        # anyway).  Returns the cue player's name.
        def cue_player(name, sound, **options)
          check_cue_name(name)
          cue_ready
          options[:at] = :now if options[:at].nil? && options[:on].nil? && options[:in].nil? && options[:start_time].nil?
          add(sound, name: Session::Name.cue(name), **options)
        end

        # Pre-listens player name +name+ (+on+) or ends it, at timeline
        # position +time+ (nil for now): its CUE gain ramps to 1 (or 0) over
        # +fade+ bars or a declick; MAIN is untouched.  Returns the Change.
        def pfl(name, on = true, time: nil, fade: nil)
          check_cue_name(name)
          cue_ready if on
          fade = bars_or_nil(fade) if fade
          change(on ? :cue : :uncue, name, time, data: { pfl: on, fade: fade }) { |_t|
            engage_split if on
            on ? @cue_pfl << name : @cue_pfl.delete(name)
            apply_cue(fade)
          }
        end

        # True if +name+ is pre-listened (see #pfl).
        def pfl?(name)
          @render_lock.synchronize { @cue_pfl.include?(name) }
        end

        # True if a cue player for +name+ is playing or waiting to start.
        def cued?(name)
          cname = Session::Name.cue(name)
          @mutex.synchronize { @players.each_value.any? { |p| p.name == cname && p.current? } } || queued_start?(cname)
        end

        # Ends the CUE of +names+ (all if none): stops their cue players over
        # +fade+ bars (a declick by default) and ends their PFLs, at +time+
        # (nil for now).  Returns the names.
        def uncue(*names, fade: nil, time: nil)
          names = names.flatten
          if names.empty?
            players = @mutex.synchronize { @players.values.map(&:name) } + @changes.map(&:subject)
            names = (players.filter_map { |n| Session::Name.cued(n) } + @render_lock.synchronize { @cue_pfl.to_a }).uniq
          end
          names.select { |n|
            cued = cued?(n)
            remove(Session::Name.cue(n), fade: fade.nil? ? declick_bars : fade, time: time) if cued
            listened = pfl?(n)
            pfl(n, false, time: time, fade: fade) if listened
            cued || listened
          }
        end

        # Moves the cue player of +name+ to MAIN at timeline position +time+
        # (nil for now): players named +name+ stop there, crossfading out
        # over +fade+ bars (a declick by default), and :"name/cue" becomes
        # +name+, ramping MAIN up and CUE down over the same fade.  Returns
        # the Change.
        def launch_cue(name, time: nil, fade: nil)
          check_cue_name(name)
          unless cued?(name)
            return MB::Sound.live_error(ArgumentError.new("Nothing cued as #{name.inspect}; cue it first (`cue #{name.inspect}, sound`)"))
          end
          fade = bars_or_nil(fade) if fade
          description = @mutex.synchronize { @players.values.select { |p| p.name == Session::Name.cue(name) && p.current? }.last&.description }
          change(:launch, name, time, data: { fade: fade, description: description }) { |t| land_launch(name, t, fade) }
        end

        # Remembers the clip a track's cue player plays (see
        # Arrangement::Cue#cue), for the launch.
        def note_cue_clip(name, clip)
          @render_lock.synchronize { @cue_clips[name] = clip }
        end

        # The clip the cue player of track +name+ plays, or nil.
        def cued_clip(name)
          @render_lock.synchronize { @cue_clips[name] }
        end

        # The names on CUE now or once the queued changes land (cue
        # players playing or waiting to start, and pre-listens), for
        # `launch` alone.
        def cued_names
          players = @mutex.synchronize { @players.values.select(&:current?).map(&:name) }
          queued = @render_lock.synchronize { @changes.select { |c| Session::START_KINDS.include?(c.kind) }.map(&:subject) }
          pfls = @render_lock.synchronize { @cue_pfl.to_a + @changes.filter_map { |c| c.subject if c.kind == :cue && c.entry&.data&.[](:pfl) } }
          ((players + queued).filter_map { |n| n.is_a?(Symbol) && Session::Name.cued(n) } + pfls).uniq.select { |n| cued?(n) || pfl_after_queue?(n) }
        end

        # True if +name+ is pre-listened, or will be once the queued
        # changes land (a `cue :x` of a playing part in a scheduled block).
        def pfl_after_queue?(name)
          @render_lock.synchronize {
            on = @cue_pfl.include?(name)
            @changes.each do |c|
              next unless c.subject == name && %i[cue uncue].include?(c.kind) && c.entry&.data&.key?(:pfl)
              on = c.entry.data[:pfl]
            end
            on
          }
        end

        # What plays on CUE: name => 'cue: description' or 'pfl'.
        def cue_info
          info = {}
          @mutex.synchronize { @players.values }.each do |p|
            n = Session::Name.cued(p.name)
            info[n] = "cue: #{p.description}" if n && p.current?
          end
          @render_lock.synchronize { @cue_pfl.to_a }.each { |n| info[n] ||= 'pfl' }
          info
        end

        private

        def init_cue(mode)
          @cue_output = :auto
          @cue_pfl = ::Set.new
          @cue_clips = {}
          @cue_knobs = nil
          @cue_parts = []
          @cue_spare = [] # (see #cue_frame)
          @cue_nil_parts = {} # (see #end_cue_span)
          @cue_span_mix = nil
          @cue_span_count = 0
          @cue_warned = false
          @cue_split_from = nil
          mode ||= ENV['CUE_OUTPUT']&.delete_prefix(':')&.to_sym
          @cue_output = mode if mode
          raise ArgumentError, "cue_output takes #{OUTPUT_MODES.map(&:inspect).join(', ')} (got #{mode.inspect})" unless OUTPUT_MODES.include?(@cue_output)
        end

        def check_cue_name(name)
          raise ArgumentError, "Cue names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "#{name.inspect} is already a cue player name; cue #{Session::Name.cued(name).inspect}" if Session::Name.cued(name)
          raise ArgumentError, "#{name.inspect} is a trigger track (a sidechain line heard only by readers such as duck(#{name.inspect})), so it never plays on CUE" if trigger_track?(name)
        end

        # Makes the phones knobs and warns once if CUE goes nowhere.
        def cue_ready
          cue_knobs
          return if @cue_warned || !MB::Sound.live?

          @cue_warned = true
          return if @cue_output == :auto && rendering_to_file? # (a render: CUE is for the live outputs)
          n = output_channel_count
          if @cue_output == :auto && n == 2 && @channels == 2
            # Once per user (maintainer 2026-10-18: "Split with a first
            # time warning; clubs are usually mono anyway")
            return if Prefs.split_warned?
            Prefs.note_split_warned
            warn "CUE on 2 channels: from the first cue, the left channel plays MAIN in mono and the right the phones mix " \
              "(cue_output :split).  `cue_output :phones` puts the phones mix on both, `cue_output :off` keeps MAIN in stereo " \
              "(CUE unheard); a 4-channel output (CUE_OUTPUT=ports) gives CUE its own channels.  (Shown once.)"
          elsif cue_mode == :off && @cue_output != :off
            warn "CUE isn't heard on this output (cue_output :#{@cue_output}, #{n} channels): " \
              "start with CUE_OUTPUT=ports and a 4-channel output, or try cue_output :split or :phones"
          end
        end

        # True when this Session renders into a file (a non-realtime
        # Session whose output #writes_file?: `render`, a take replayed to a
        # file), which :auto keeps CUE out of (see #cue_mode).
        def rendering_to_file?
          return false if @realtime || !output_open?
          o = output
          o.respond_to?(:writes_file?) && o.writes_file?
        end

        # Notes the frame where CUE is first used (a cue player starting or
        # a PFL landing): :auto splits a 2-channel output from there.
        def engage_split
          @cue_split_from ||= @landing_frame || @frame
        end

        # A player starting as +name+ (not a cue player) ends +name+'s cue
        # player at the same time (`bg :x` or `go` replacing :x; maintainer
        # 2026-10-18).  Called by Session#add after queuing the start.
        def end_cue_at_start(name, time)
          return unless name.is_a?(Symbol) && Session::Name.cued(name).nil? && cued?(name)
          remove(Session::Name.cue(name), fade: declick_bars, time: time)
        end

        # The output channels and cue channels for opening the output (see
        # Session#output): twice the channels when CUE gets its own ports.
        def output_channels
          @cue_output == :ports ? [@channels * 2, @channels] : [@channels, 0]
        end

        # How many channels the output takes (the Session's channels for
        # outputs that don't say with an Integer).
        def output_channel_count
          n = output.respond_to?(:channels) ? output.channels : nil
          n.is_a?(Integer) ? n : @channels
        end

        # The starting route of a new player named +name+ (nil for MAIN
        # only).
        def initial_cue_levels(name)
          cue = Session::Name.cued(name)
          return nil unless cue || @cue_pfl.include?(name)
          engage_split
          Levels.new(cue ? 0.0 : 1.0, nil, 1.0, nil)
        end

        # Ramps every player's route toward its targets from the landing
        # frame, over +fade+ bars or a declick: MAIN 0 for cue players,
        # else 1; CUE 1 for cue players and pre-listened names, else 0.
        def apply_cue(fade)
          frame = @landing_frame || @frame
          rate = output.sample_rate.to_f
          length = fade ? fade_frames(fade, rate) : MB::M.max((Fades::DECLICK_SECONDS * rate).round, 1)

          @mutex.synchronize { @players.values }.each do |p|
            cue = !Session::Name.cued(p.name).nil?
            main_t = cue ? 0.0 : 1.0
            cue_t = cue || @cue_pfl.include?(p.name) ? 1.0 : 0.0
            l = p.cue
            next if l.nil? && main_t == 1.0 && cue_t == 0.0

            l = p.cue = Levels.new(1.0, nil, 0.0, nil) if l.nil?
            [[:main_level, :main_ramp, main_t], [:cue_level, :cue_ramp, cue_t]].each do |lf, rf, target|
              current = l[rf] ? l[rf].to : l[lf]
              next if current == target
              l[rf] = Fades::Ramp.after(l[rf], l[lf], target, frame, length)
            end
          end
        end

        # The :launch change's action (see #launch_cue).
        def land_launch(name, time, fade)
          cname = Session::Name.cue(name)
          @mutex.synchronize {
            cp = @players.values.select { |p| p.name == cname && p.current? }.last
            # (a later `bg`, `go`, or `tweak` started a new :name before the
            # launch landed, stopping the cue as it does: the launch lands as
            # nothing, never an error on the render thread; omnibus15, the
            # session fuzz's cue/launch step, seeds 6 and 20)
            return unless cp
            switch_cue_player(cp, name, time, fade || declick_bars)
          }
          apply_cue(fade)
          apply_strip(fade)
        end

        # Renames player +p+ to +name+ (to or from MAIN), stopping the
        # current players named +name+ at +time+ over +fade+ bars.  Called
        # with @mutex held.
        def switch_cue_player(p, name, time, fade)
          @players.each_value do |o|
            next unless o.name == name && o.current? && !o.equal?(p)
            if o.started
              o.stop_at = time
              o.fade_out = fade
              o.keep = true
            else
              @players.delete(o.serial)
            end
          end
          old = p.name
          p.name = name
          @order.delete(old) unless @players.each_value.any? { |o| o.name == old }
          @order.delete(name)
          @order << name
        end

        # Adds a cued player's sound to the cue mix and returns its MAIN
        # gains (combined with +ramp+, its fade and strip gains; nil for
        # full level).  Called by #render_player for players with a route.
        def cue_route(p, data, ramp, offset, frames, frame)
          l = p.cue
          if l.main_ramp.nil? && l.cue_ramp.nil? && l.main_level == 1.0 && l.cue_level == 0.0
            p.cue = nil # back to MAIN only
            return ramp
          end

          main = ramp_levels(l, :main_level, :main_ramp, frame, frames)
          if l.cue_ramp || l.cue_level != 0.0
            cue = ramp_levels(l, :cue_level, :cue_ramp, frame, frames)
            add_cue(data, cue && ramp ? cue * ramp : (cue || ramp), offset, frames)
          end

          return ramp if main.nil?
          ramp ? ramp * main : main
        end

        # Adds +data+ times +gains+ (nil for 1) to the span's cue mix.
        def add_cue(data, gains, offset, frames)
          mix = (@cue_span_mix ||= Array.new(@channels) { Numo::SFloat.zeros(@cue_span_count) })
          mix.each_with_index do |m, c|
            d = data[c % data.length]
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            len = MB::M.min(d.length, frames)
            d = d[0...len]
            d = d * gains[0...len] if gains
            m[offset...(offset + len)].inplace + d
          end
        end

        # Before a span's players render (see #render_span).
        def begin_cue_span(count)
          @cue_span_mix = nil
          @cue_span_count = count
        end

        # After the span's master chain (+mix+ the MAIN mix, +count+
        # frames): what the output gets for the span (MAIN with the phones
        # mix added or blended in per #cue_mode), or nil for MAIN alone,
        # kept for #cue_frame.
        def end_cue_span(mix, count)
          cue = @cue_span_mix
          @cue_span_mix = nil
          mode = cue_mode
          want = output_channel_count
          if want == mix.length && mode != :split && mode != :phones
            @cue_parts << ((@cue_nil_parts ||= {})[count] ||= [count, nil].freeze) # (one frozen pair per length: every span)
            return
          end

          post = @master_gain_post && @master_gain != 1 ? @master_gain : nil
          main = post ? mix.map { |m| m * post } : mix
          phones = phones_mix(main, cue, count)
          out =
            case mode
            when :split then want == 2 ? [mono(main), mono(phones)] : nil
            when :phones then want == phones.length ? phones : nil
            when :ports then main + phones.first(want - main.length)
            end
          out ||= pad(main, want, count)

          # :auto splits from the frame the first cue landed on (see
          # #engage_split); before it, MAIN as it was
          k = @cue_split_from && @cue_output == :auto && mode == :split ? @cue_split_from - @frame : 0
          if k > 0
            plain = pad(main, want, count)
            out = out.each_with_index.map { |o, c| k >= count ? plain[c] : plain[c][0...k].concatenate(o[k..]) }
          end
          @cue_parts << [count, out]
        end

        # The phones mix for a span: CUE and +main+ blended by :cue_mix,
        # scaled by :phones.
        def phones_mix(main, cue, count)
          knobs = @cue_knobs
          return cue || Array.new(@channels) { Numo::SFloat.zeros(count) } if knobs.nil?

          level = knobs[0].read(@frame, count)
          blend = knobs[1].read(@frame, count)
          Array.new(@channels) { |c|
            x = cue ? cue[c] : nil
            if blend.is_a?(Numeric) && blend == 0
              x ||= Numo::SFloat.zeros(count)
            else
              m = main[c] * blend
              x = x ? x * (1.0 - blend) + m : m
            end
            level.is_a?(Numeric) && level == 1 ? x : x * level
          }
        end

        def pad(chans, want, count)
          return chans if chans.length == want
          return chans.first(want) if chans.length > want
          chans + Array.new(want - chans.length) { Numo::SFloat.zeros(count) }
        end

        # What #process_buffer writes for MAIN mix +mix+ (after the
        # post-chain master gain): the spans #end_cue_span composed, or the
        # mix itself.
        def cue_frame(mix, count)
          # (two Arrays in turn: a new one every buffer before; dropouts-2)
          parts = @cue_parts
          @cue_parts = (@cue_spare ||= [])
          @cue_spare = parts
          if parts.all? { |_, out| out.nil? }
            parts.clear
            return mix
          end

          want = output_channel_count
          offset = 0
          chunks = parts.map { |n, out|
            out ||= pad(mix.map { |m| m[offset...(offset + n)] }, want, n)
            offset += n
            out
          }
          parts.clear
          chunks.length == 1 ? chunks[0] : chunks.transpose.map { |chans| chans.reduce { |a, b| a.concatenate(b) } }
        end

        def mono(chans)
          return chans[0] if chans.length == 1
          chans.reduce { |a, b| a + b } * (1.0 / chans.length)
        end

        # Cue players ignore solos (a solo is about MAIN); `mute :x` mutes
        # :"x/cue" too.
        def audible_unlocked?(name)
          base = Session::Name.cued(name)
          return super unless base
          !@muted.include?(name) && !@muted.include?(base)
        end

        def snapshot_subject(c)
          return CueSubject.new(c.subject) if KINDS.include?(c.kind) || c.entry.data[:cue]
          super
        end

        def undo_snapshot(subject)
          return super unless subject.is_a?(CueSubject)
          name = subject.name
          cname = Session::Name.cue(name)
          serial = @mutex.synchronize { @players.values.select { |p| p.name == cname && p.current? }.last&.serial }
          CueState.new(pfl: @cue_pfl.include?(name), cue_serial: serial, main: super(name))
        end

        def restore_change(subject, original, time)
          return super unless subject.is_a?(CueSubject)
          state = original.before
          full = original.kind == :launch || original.entry.data[:cue] == :full
          change(:restore, subject.name, time, data: { cue: full ? :full : :pfl }, undoes: original.seq) { |t|
            restore_cue(subject.name, state, t, full)
          }
        end

        # Puts name +name+'s CUE back to +state+ (a CueState): its PFL and,
        # if +full+, which graph is cued and which is on MAIN (renaming
        # players back and forth, so no graph restarts while it plays).
        def restore_cue(name, state, time, full)
          state.pfl ? @cue_pfl << name : @cue_pfl.delete(name)
          if full
            cname = Session::Name.cue(name)
            declick = declick_bars
            restored = false
            @mutex.synchronize {
              c = state.cue_serial && @players[state.cue_serial]
              switch_cue_player(c, cname, time, declick) if c && c.current? && c.name == name
              m = state.main&.player && @players[state.main.player.serial]
              if m && m.current? && m.name == cname
                switch_cue_player(m, name, time, declick)
                restored = true
              end
            }
            restore_player(name, state.main, time) unless restored || state.main.nil?
          end
          apply_cue(nil)
          apply_strip(nil)
        end
      end
    end
  end
end
