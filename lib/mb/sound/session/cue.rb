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
        # Where CUE goes (see #cue_output=).
        OUTPUT_MODES = [:auto, :ports, :split, :phones, :off].freeze

        # The suffix of cue player names (:"lead/cue").
        SUFFIX = '/cue'

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

        # The cue player name for +name+ (:lead -> :"lead/cue").
        def self.cue_name(name)
          :"#{name}#{SUFFIX}"
        end

        # The name a cue player name stands for (:"lead/cue" -> :lead), or
        # nil.
        def self.cued_name(name)
          return nil unless name.is_a?(Symbol)
          s = name.name
          s.end_with?(SUFFIX) && s.length > SUFFIX.length ? s[0...-SUFFIX.length].to_sym : nil
        end

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
        def cue_mode
          return @cue_output unless @cue_output == :auto
          output_open? && output_channel_count >= @channels * 2 ? :ports : :off
        end

        # The phones knobs [:phones, :cue_mix], made on first use (a knob
        # already defined under either name is used as it is).
        def cue_knobs
          @cue_knobs ||= [
            knobs[:phones] || knob(:phones, 1.0, range: 0.0..2.0),
            knobs[:cue_mix] || knob(:cue_mix, 0.0, range: 0.0..1.0),
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
          add(sound, name: Cue.cue_name(name), **options)
        end

        # Pre-listens player name +name+ (+on+) or ends it, at timeline
        # position +time+ (nil for now): its CUE gain ramps to 1 (or 0) over
        # +fade+ bars or a declick; MAIN is untouched.  Returns the Change.
        def pfl(name, on = true, time: nil, fade: nil)
          check_cue_name(name)
          cue_ready if on
          fade = bars_or_nil(fade) if fade
          change(on ? :cue : :uncue, name, time, data: { pfl: on, fade: fade }) { |_t|
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
          cname = Cue.cue_name(name)
          @mutex.synchronize { @players.each_value.any? { |p| p.name == cname && p.current? } } || queued_start?(cname)
        end

        # Ends the CUE of +names+ (all if none): stops their cue players over
        # +fade+ bars (a declick by default) and ends their PFLs, at +time+
        # (nil for now).  Returns the names.
        def uncue(*names, fade: nil, time: nil)
          names = names.flatten
          if names.empty?
            players = @mutex.synchronize { @players.values.map(&:name) } + @changes.map(&:subject)
            names = (players.filter_map { |n| Cue.cued_name(n) } + @render_lock.synchronize { @cue_pfl.to_a }).uniq
          end
          names.select { |n|
            cued = cued?(n)
            remove(Cue.cue_name(n), fade: fade.nil? ? declick_bars : fade, time: time) if cued
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
          change(:launch, name, time, data: { fade: fade }) { |t| land_launch(name, t, fade) }
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

        # What plays on CUE: name => 'cue: description' or 'pfl'.
        def cue_info
          info = {}
          @mutex.synchronize { @players.values }.each do |p|
            n = Cue.cued_name(p.name)
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
          @cue_span_mix = nil
          @cue_span_count = 0
          @cue_warned = false
          mode ||= ENV['CUE_OUTPUT']&.delete_prefix(':')&.to_sym
          @cue_output = mode if mode
          raise ArgumentError, "cue_output takes #{OUTPUT_MODES.map(&:inspect).join(', ')} (got #{mode.inspect})" unless OUTPUT_MODES.include?(@cue_output)
        end

        def check_cue_name(name)
          raise ArgumentError, "Cue names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "#{name.inspect} is already a cue player name; cue #{Cue.cued_name(name).inspect}" if Cue.cued_name(name)
        end

        # Makes the phones knobs and warns once if CUE goes nowhere.
        def cue_ready
          cue_knobs
          return if @cue_warned || !MB::Sound.live? || cue_mode != :off

          @cue_warned = true
          warn "CUE isn't heard on this output (cue_output :#{@cue_output}, #{output_channel_count} channels): " \
            "start with CUE_OUTPUT=ports and a 4-channel output, or try cue_output :split or :phones"
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
          cue = Cue.cued_name(name)
          return nil unless cue || @cue_pfl.include?(name)
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
            cue = !Cue.cued_name(p.name).nil?
            main_t = cue ? 0.0 : 1.0
            cue_t = cue || @cue_pfl.include?(p.name) ? 1.0 : 0.0
            l = p.cue
            next if l.nil? && main_t == 1.0 && cue_t == 0.0

            l = p.cue = Levels.new(1.0, nil, 0.0, nil) if l.nil?
            [[:main_level, :main_ramp, main_t], [:cue_level, :cue_ramp, cue_t]].each do |lf, rf, target|
              current = l[rf] ? l[rf].to : l[lf]
              next if current == target
              level = l[rf] ? l[rf].at(frame) : l[lf]
              l[rf] = Fades::Ramp.new(level, target, frame, length)
            end
          end
        end

        # The :launch change's action (see #launch_cue).
        def land_launch(name, time, fade)
          cname = Cue.cue_name(name)
          @mutex.synchronize {
            cp = @players.values.select { |p| p.name == cname && p.current? }.last
            raise "Nothing cued as #{name.inspect}" unless cp
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
        # frames): the phones mix for the span, kept for #cue_frame.
        def end_cue_span(mix, count)
          cue = @cue_span_mix
          @cue_span_mix = nil
          return unless output_channel_count > mix.length || [:split, :phones].include?(cue_mode)

          knobs = @cue_knobs
          if knobs.nil?
            @cue_parts << (cue || Array.new(@channels) { Numo::SFloat.zeros(count) })
            return
          end

          level = knobs[0].read(@frame, count)
          blend = knobs[1].read(@frame, count)
          post = @master_gain_post && @master_gain != 1 ? @master_gain : nil
          phones = Array.new(@channels) { |c|
            x = cue ? cue[c] : nil
            if blend.is_a?(Numeric) && blend == 0
              x ||= Numo::SFloat.zeros(count)
            else
              m = post ? mix[c] * post : mix[c]
              m = m * blend
              x = x ? x * (1.0 - blend) + m : m
            end
            level.is_a?(Numeric) && level == 1 ? x : x * level
          }
          @cue_parts << phones
        end

        # What #process_buffer writes for MAIN mix +mix+ (+count+ frames):
        # the mix with the phones channels added or blended in per
        # #cue_mode (see #end_cue_span).
        def cue_frame(mix, count)
          parts = @cue_parts
          @cue_parts = []
          want = output_channel_count
          return mix if parts.empty? && want == mix.length

          phones = parts.length == 1 ? parts[0] : parts.transpose.map { |chans| chans.reduce { |a, b| a.concatenate(b) } }
          phones ||= Array.new(@channels) { Numo::SFloat.zeros(count) }
          case cue_mode
          when :split
            return mix unless want == 2
            [mono(mix), mono(phones)]
          when :phones
            want == phones.length ? phones : mix
          when :ports
            mix + phones.first(want - mix.length)
          else
            want > mix.length ? mix + Array.new(want - mix.length) { Numo::SFloat.zeros(count) } : mix
          end
        end

        def mono(chans)
          return chans[0] if chans.length == 1
          chans.reduce { |a, b| a + b } * (1.0 / chans.length)
        end

        # Cue players ignore solos (a solo is about MAIN); `mute :x` mutes
        # :"x/cue" too.
        def audible_unlocked?(name)
          base = Cue.cued_name(name)
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
          cname = Cue.cue_name(name)
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
            cname = Cue.cue_name(name)
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
