module MB
  module Sound
    class Session
      # Mute and solo for Session players: the mute/solo stage of each
      # player's strip (contract K7: fade, then gain, then mute/solo).
      #
      # Mutes and solos belong to player names, so a graph replacing a muted
      # one starts muted.  An armed track's monitor player follows its
      # track's mute and solo.  They apply right away with a short declick ramp
      # (DECLICK_SECONDS), or at a launch point (+:at+) and over a +:fade+
      # in bars, through the change queue like every other change.
      #
      # A player that is silent because of a mute or solo sleeps: its graph
      # isn't rendered at all (no CPU), so its state goes stale.  When it
      # wakes, its clips and tempo-synced oscillators move to the timeline
      # like after a seek, so they come back in time; free-running
      # oscillators, envelopes, delays, and reverbs carry on from where they
      # stopped.
      module Strip
        # Mutes the players named +names+ (or mute groups; see #mute_group).
        # Returns the changes (see Changes#change).
        def mute(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          strip_change(:mute, names, at: point, fade: fade, start_time: start_time) { |n| @muted << n }
        end

        # Unmutes the named players (all muted players if none are named:
        # those muted when the change lands).
        def unmute(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return strip_all_change(:unmute, at: point, fade: fade, start_time: start_time) { @muted.clear } if names.empty?
          strip_change(:unmute, names, at: point, fade: fade, start_time: start_time) { |n| @muted.delete(n) }
        end

        # Solos the named players: while any player is soloed, players that
        # aren't are silent.  With no names, clears every solo (see #unsolo).
        def solo(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return unsolo(at: point, fade: fade, start_time: start_time) if names.empty?
          strip_change(:solo, names, at: point, fade: fade, start_time: start_time) { |n| @soloed << n }
        end

        # Clears the solo of the named players (all solos if none are named:
        # those soloed when the change lands, so a queued solo isn't missed).
        def unsolo(*names, at: nil, on: nil, in: nil, fade: nil, start_time: nil)
          point = LaunchPoint.of(binding) or return nil
          return strip_all_change(:unsolo, at: point, fade: fade, start_time: start_time) { @soloed.clear } if names.empty?
          strip_change(:unsolo, names, at: point, fade: fade, start_time: start_time) { |n| @soloed.delete(n) }
        end

        # Defines a mute group: +name+ stands for the players +names+ in
        # #mute, #unmute, #solo, and #unsolo (an MPC-style mute group, e.g.
        # `mute_group :breakdown, :drums, :bass` and then `mute :breakdown`).
        # Pass no names to remove the group.  Returns the group's names.
        def mute_group(name, *names)
          names = names.flatten
          return nil unless names.empty? || @names.claim(name, :group)

          @render_lock.synchronize {
            if names.empty?
              @mute_groups.delete(name)
            else
              @mute_groups[name] = names.freeze
            end
          }
          names
        end

        # The mute groups (a Hash from group name to player names).
        def mute_groups
          @render_lock.synchronize { @mute_groups.dup }
        end

        # True if +name+ is muted (once queued changes have landed, if
        # +projected+).
        def muted?(name)
          @render_lock.synchronize { @muted.include?(name) }
        end

        # True if +name+ is soloed.
        def soloed?(name)
          @render_lock.synchronize { @soloed.include?(name) }
        end

        # True if a player named +name+ would be heard (not muted, and
        # soloed if anything is).
        def audible?(name)
          @render_lock.synchronize { audible_unlocked?(name) }
        end

        # The mute and solo state: a Hash with the +:muted+ and +:soloed+
        # names, the mute +:groups+, and +:queued+ mute/solo changes.
        def strip_info
          @render_lock.synchronize {
            {
              muted: @muted.to_a,
              soloed: @soloed.to_a,
              groups: @mute_groups.dup,
              queued: @changes.select { |c| STRIP_KINDS.include?(c.kind) }.map(&:entry),
            }
          }
        end

        # Change kinds for mutes and solos.
        STRIP_KINDS = [:mute, :unmute, :solo, :unsolo].freeze

        private

        def init_strip
          @muted = ::Set.new
          @soloed = ::Set.new
          @mute_groups = {}
          @landing_frame = nil
        end

        # Expands mute group names.
        def expand_mute_groups(names)
          names.flat_map { |n| @mute_groups.key?(n) ? @mute_groups[n] : [n] }.uniq
        end

        # Queues one mute/solo change per name at the launch point (now by
        # default), each calling +update+ with the name when it lands.
        def strip_change(kind, names, at:, fade:, start_time:, &update)
          names = expand_mute_groups(names.flatten)
          fade = bars_or_nil(fade) if fade
          time = start_time ? start_time.to_r : launch_time(at, [], default: nil)

          names.map { |n|
            change(kind, n, time, data: { fade: fade }) { |_t|
              update.call(n)
              apply_strip(fade)
            }
          }
        end

        # Queues one change to every player's mute or solo flags (subject
        # :strip), calling +update+ when it lands.  Returns the changes.
        def strip_all_change(kind, at:, fade:, start_time:, &update)
          fade = bars_or_nil(fade) if fade
          time = start_time ? start_time.to_r : launch_time(at, [], default: nil)
          [change(kind, :strip, time, data: { fade: fade }) { |_t| update.call; apply_strip(fade) }]
        end

        # Puts every mute and solo flag back to a StripState (for undo).
        def restore_strip(state, fade = nil)
          @muted.replace(state.muted)
          @soloed.replace(state.soloed)
          apply_strip(fade)
        end

        # True if a player named +name+ should be heard.  Called with
        # @render_lock held.  An armed track's monitor (:"lead/live"; see
        # Arrangement::Recording) follows its track's flags as well as its
        # own: `mute :lead` silences the keyboard through :lead's patch
        # too, and `solo :lead` keeps it (omnibus6, agreed 2026-10-12).
        def audible_unlocked?(name)
          track = Arrangement::Recording.monitored_track(name)
          return false if @muted.include?(name) || (track && @muted.include?(track))
          @soloed.empty? || @soloed.include?(name) || (!track.nil? && @soloed.include?(track))
        end

        # Ramps every player whose mute/solo level should change, starting
        # at the frame where the current change lands (see
        # Changes#commit_change), over +fade+ bars or DECLICK_SECONDS.
        def apply_strip(fade)
          frame = @landing_frame || @frame
          rate = output.sample_rate.to_f
          length = fade ? fade_frames(fade, rate) : MB::M.max((Fades::DECLICK_SECONDS * rate).round, 1)

          @mutex.synchronize { @players.values }.each do |p|
            target = audible_unlocked?(p.name) ? 1.0 : 0.0
            current_target = p.strip_ramp ? p.strip_ramp.to : p.strip_level
            next if current_target == target

            level = p.strip_ramp ? p.strip_ramp.at(frame) : p.strip_level
            p.strip_ramp = Fades::Ramp.new(level, target, frame, length)
          end
        end

        # Reads sleeping player +p+'s branches of nodes that other players
        # also play (see #asleep_reads) for +frames+ frames, so their Tees
        # keep it in step: before, the Tee left it a whole CircularBuffer
        # behind after a second asleep, and unmuting raised
        # BranchBufferOverflow.  The player's own nodes still sleep.
        def read_while_asleep(p, frames)
          return if frames <= 0

          asleep_reads(p).each { |b| b.sample(frames) }
        end

        # What sleeping player +p+ still reads (like a skipped Synth lane;
        # see Synth#boundary): its branches of Tees with a branch in another
        # player's graph (sleeping or not), less those that another of
        # these reads through.  Branches nothing in the Session plays (an
        # unused `lfo * 2`, or a graph not started yet) don't count: reading
        # for them would run the node while the player sleeps, so a muted
        # player's sound would depend on unused nodes.  Cached until a Tee
        # gains or loses a branch or the players change.
        def asleep_reads(p)
          players = @span_players || @mutex.synchronize { @players.values }
          # One list of the players' serials per span, the same object while
          # the players stay the same
          serials = (@span_serials ||= begin
            list = players.map(&:serial)
            list == @asleep_serials ? @asleep_serials : (@asleep_serials = list)
          end)
          changes = GraphNode::Tee.branch_changes
          cache = p.asleep_reads
          return cache[2] if cache && cache[0] == changes && cache[1].equal?(serials)

          own = p.input.graph(include_tees: true)
          set = own.to_h { |n| [n.__id__, true] }
          others = {}
          players.each do |o|
            next if o.equal?(p)

            o.input.graph(include_tees: true).each { |n| others[n.__id__] = true }
          end

          shared = own.select { |n|
            n.is_a?(GraphNode::Tee::Branch) && n.owner_tee.branches.any? { |b| !set[b.__id__] && others[b.__id__] }
          }
          upstream = {}
          shared.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          shared.reject! { |n| upstream[n.__id__] }

          p.asleep_reads = [changes, serials, shared]
          shared
        end

        # The mute/solo level a new player named +name+ starts at.
        def initial_strip_level(name)
          audible_unlocked?(name) ? 1.0 : 0.0
        end
      end
    end
  end
end
