module MB
  module Sound
    class Session
      # Clearing the set (fixes-15; the maintainer, 2026-11-18: "A new demo
      # should replace the entire previous demo"): #clear_set stops what
      # plays and takes the set's definitions out of the Session in one
      # undo step, so a demo (DemoMethods#demo) or a set document loads
      # into an empty set instead of on top of the last one, whose names
      # would clash (Night Bus's knob :echo, Tunnel Vision's bus :echo).
      #
      # The set is the state a set document declares: the Arrangement
      # (tracks, scenes, sections, the flow, the clip matrix, the demo
      # document), the namespace (Names), knobs and knob snapshots, racks,
      # markers, metadata, clocks, mutes, solos, and mute groups, buses,
      # routes, sends, and sidechain triggers, and the master chain.  The
      # tempo, meter, key, tuning, master gain, monitor trim, and takes stay.
      #
      # Undo swaps the whole set back (SetSwap: the same objects, so the
      # undone set's graphs and knobs come back as they were, like #resume)
      # and its players come back at the undo's launch point; redo swaps
      # the cleared one in again.
      module SetClear
        # Everything #clear_set takes out, by reference (see the module
        # comment): what SetSwap puts back.
        SetState = Data.define(
          :arrangement, :names, :knobs, :snapshots, :racks, :markers, :metadata, :clocks,
          :muted, :soloed, :mute_groups,
          :buses, :bus_defs, :routes, :trigger_routes, :trigger_shapes, :send_knobs,
          :master_block, :master_preset
        )

        # The undo participant of #clear_set (see Undo#note_undo_extra):
        # puts a SetState in.
        class SetSwap
          def initialize(session)
            @session = session
          end

          def restore_undo_state(state)
            @session.send(:install_set_state, state)
          end
        end

        # Stops everything (players now, without fades; queued changes,
        # scheduled blocks, and the flow dropped, as #panic does) and takes
        # the set out of the Session (see SetClear), as one undo step
        # labeled +label+.  Refused, with why, while a track is armed or
        # wired (disarm or unwire it first).
        #
        # With a block, runs it after clearing as part of the same step
        # (what it changes is not undone on its own: undo swaps the whole
        # set back, redo puts in the set the block made); DemoMethods#demo
        # loads its set document there.  Returns the block's value (true
        # without a block), or nil when refused live.
        def clear_set(label: 'clear_set')
          raise IOError, 'Session is closed' if @closed
          arr = arrangement
          held = arr.arms
          unless held.empty?
            what = held.map { |n, a| "#{n.inspect} is #{a.wired? ? 'wired (unwire' : 'armed (disarm'} #{n.inspect} first)" }
            return MB::Sound.live_error(ArgumentError.new("#{label}: #{what.join('; ')}"))
          end

          swap = SetSwap.new(self)
          result = true
          error = nil
          Session.with_context(session: self) do
            command(label) do
              reset_scheduler
              waiting = queued
              cancel_changes(*waiting.map(&:seq)) unless waiting.empty?
              stopping = @mutex.synchronize { !@players.empty? }
              remove(fade: 0)
              forget
              before = set_state
              install_set_state(empty_set_state)
              note_undo_extra(swap, before, set_state)
              if block_given?
                # (the stops land first, so what the block launches lands
                # now, as in a quiet Session, not at the next bar)
                settle_stops if stopping
                # (the block's own commands join a group nobody keeps: undo
                # swaps the set they made out whole)
                begin
                  result = Session.with_context_fields(command: Undo::CommandGroup.new(self)) { yield }
                rescue StandardError => e
                  error = e # (raised after the step is kept: undo puts the set back)
                end
                note_undo_extra(swap, before, set_state)
              end
            end
          end
          raise error if error

          result
        end

        # What the set holds, for messages: "12 tracks, 12 scenes, 5 knobs,
        # a master chain, and a flow", led by the demo it came from ("demo
        # :night_bus: ..."); empty for an empty set.
        def set_summary
          arr = arrangement
          count = ->(n, what) { n.zero? ? nil : "#{n} #{what}#{'s' unless n == 1}" }
          parts = [
            count.(arr.tracks.length, 'track'), count.(arr.scenes.length, 'scene'),
            count.(@knob_lock.synchronize { @knobs.length }, 'knob'), count.(@mutex.synchronize { @buses.length }, 'bus').to_s.sub(/buss\z/, 'buses'),
            (@master_block || @master_preset) && 'a master chain', arr.last_form && 'a flow',
          ].reject { |p| p.nil? || p.empty? }
          text = parts.length > 1 ? "#{parts[0..-2].join(', ')}, and #{parts.last}" : parts.join
          doc = arr.demo_document&.path
          doc && !text.empty? ? "demo #{File.basename(doc, GraphIO::EXTENSION).to_sym.inspect} (#{text})" : text
        end

        private

        # The set as it is now (see SetState).
        def set_state
          @render_lock.synchronize {
            SetState.new(
              arrangement: arrangement, names: @names, knobs: @knobs, snapshots: @snapshots, racks: @racks,
              markers: @markers, metadata: @metadata, clocks: @clocks,
              muted: @muted, soloed: @soloed, mute_groups: @mute_groups,
              buses: @buses, bus_defs: @bus_defs, routes: @routes, trigger_routes: @trigger_routes,
              trigger_shapes: @trigger_shapes, send_knobs: @send_knobs,
              master_block: @master_block, master_preset: @master_preset
            )
          }
        end

        # Lets the stops #clear_set issued land: a buffer at a time
        # without a render thread (as DemoMethods#demo did before), else
        # waiting for the render thread, up to SETTLE_SECONDS.
        def settle_stops
          if realtime?
            deadline = MB::U.clock_now + SETTLE_SECONDS
            Internal.wait_audio(self, 0.005) until @mutex.synchronize { @players.empty? } || MB::U.clock_now > deadline
          else
            SETTLE_BUFFERS.times do
              break if @mutex.synchronize { @players.empty? }
              process_buffer
            end
          end
        end

        # How long #settle_stops waits for a render thread.
        SETTLE_SECONDS = 1.0

        # The most buffers #settle_stops renders without one.
        SETTLE_BUFFERS = 4

        # A set with nothing in it (new objects every time).
        def empty_set_state
          SetState.new(
            arrangement: Arrangement.new(self), names: Names.new, knobs: {}, snapshots: {}, racks: Racks.new(self),
            markers: nil, metadata: Meta::Store.new, clocks: {},
            muted: ::Set.new, soloed: ::Set.new, mute_groups: {},
            buses: {}, bus_defs: {}, routes: {}, trigger_routes: false, trigger_shapes: {}, send_knobs: [],
            master_block: nil, master_preset: nil
          )
        end

        # Puts +state+ (a SetState) in as the Session's set, under the
        # render lock (the next buffer renders it), then its master chain
        # (now, no fade) if it differs.  The master change is kept out of
        # any undo step: SetSwap carries the chain.
        def install_set_state(state)
          # (each field one assignment, under the render lock and the
          # session's mutex; readers holding the knob or clock lock see
          # the old Hash or the new one)
          @render_lock.synchronize {
            @mutex.synchronize {
              @arrangement = state.arrangement
              @names = state.names
              @knobs = state.knobs
              @snapshots = state.snapshots
              @racks = state.racks
              @markers = state.markers
              @metadata = state.metadata
              @clocks = state.clocks
              @muted = state.muted
              @soloed = state.soloed
              @mute_groups = state.mute_groups
              @buses = state.buses
              @bus_defs = state.bus_defs
              @routes = state.routes
              @trigger_routes = state.trigger_routes
              @trigger_shapes = state.trigger_shapes
              @send_knobs = state.send_knobs
              @bus_order = nil
            }
          }
          return if @master_block.equal?(state.master_block) && @master_preset.equal?(state.master_preset)

          Session.with_context_fields(command: Undo::CommandGroup.new(self)) {
            master(state.master_preset, on: :now, fade: 0, &state.master_block)
          }
        end
      end
    end
  end
end
