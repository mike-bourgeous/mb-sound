module MB
  module Sound
    class Session
      # Changes the clips a player's graph plays without replacing the graph
      # (see #swap), so synths, filters, and effects keep their settings and
      # state (e.g. reverb tails) while the notes change.
      module ClipSwaps
        # Swaps clips in the graph of the player named +name+ when the
        # timeline reaches the launch point (+:on+, +:in+, +:at+; the next
        # bar by default; see #add and LaunchPoint) or +:start_time+, on the exact sample.  Returns the number
        # of clip sources (MIDI::ClipSource, found in the graph like other
        # timeline nodes) that will change.
        #
        # +clips+ is either a Hash from old clips to new clips, or a single new
        # clip to replace the clip that every clip in the graph was made from
        # (e.g. both `bass` and `bass.transpose(12)` come from `bass`).
        # Clips made from a replaced clip with transforms like #transpose,
        # or #legato are rebuilt from the new clip with the same transforms
        # (a Clip#synth reads its clip through one source, so its voices
        # follow the swap like any other clip node).  Drum kits from #grid (or Hashes of clips) may
        # be given as keys and values to swap each row with the same name,
        # or a new Kit alone: each row the player plays (found by the row
        # names its clips had in their kit) plays the new kit's row of that
        # name, and rows the new kit lacks go silent, as when a scene
        # swaps kits (rows only the new kit has need voices the graph
        # doesn't have: a warning, as scenes build the patch again then).
        #
        # Looping clips play in phase with the timeline; launch-aligned
        # loops (Clip#loop with +align: :launch+) start at their beginning on
        # the swap and keep that anchor through later seeks; non-looping
        # clips play from their start and end the graph when they finish.
        #
        # Stopped players (see #remove) can be swapped too; the new clips play
        # when they are resumed.
        #
        # The swap goes through the change queue (see Changes), so a player
        # can have several swaps waiting for different times; each is worked
        # out from the clips playing when it lands.  Errors that are already
        # clear when the swap is made (no such player, no clips, unrelated
        # clips) are raised right away.
        def swap(name, clips, at: nil, on: nil, in: nil, start_time: nil)
          raise IOError, 'Session is closed' if @closed
          point = LaunchPoint.of(binding) or return nil

          _player, stopped, nodes = @render_lock.synchronize { @mutex.synchronize { swap_target(name) } }
          count = planned_swaps(name, nodes, clips, warn: true).length

          time = stopped ? nil : (start_time ? start_time.to_r : launch_time(point, nodes))
          change(:swap, name, time, data: { clip: clip_label(clips) }) { |t|
            swap_now(name, clips, stopped ? nil : t)
          }

          count
        end

        private

        # True if #swap_now has something to swap for +name+: a current or
        # stopped player, or a start waiting in the change queue (a capture
        # landing after its track was removed, e.g. in a render's tail, has
        # none).  Called with @render_lock held.
        def swap_target?(name)
          @mutex.synchronize {
            @players.each_value.any? { |p| p.name == name && p.current? } || @stopped.key?(name) ||
              @changes.any? { |c| c.subject == name && c.starts }
          }
        end

        # Finds the player whose clips #swap changes: the current player
        # named +name+, the stopped one, or the one waiting in the change
        # queue to start.  Returns [player, stopped?, clip sources].  Called
        # with @render_lock and @mutex held.
        def swap_target(name)
          player = @players.values.select { |p| p.name == name && p.current? }.last
          stopped = player.nil? && @stopped.key?(name)
          player ||= @stopped[name]

          if player.nil?
            nodes = @changes.select { |c| c.subject == name && c.starts }.last&.starts&.grep(MIDI::ClipSource)
            raise ArgumentError, "No background player #{name.inspect} is playing or stopped" if nodes.nil?
          else
            nodes = player.timeline_nodes.grep(MIDI::ClipSource)
          end

          raise ArgumentError, "Player #{name.inspect} doesn't play any clips" if nodes.empty?
          [player, stopped, nodes]
        end

        # Returns [node, new clip] pairs for swapping +clips+ into the clip
        # sources +nodes+, raising if none of them change.
        def planned_swaps(name, nodes, clips, warn: false)
          mapping = case clips
                    when Sequence::Clip then auto_swap_mapping(name, nodes, clips)
                    when Sequence::Kit then kit_swap_mapping(name, nodes, clips, warn: warn)
                    else swap_mapping(clips)
                    end

          # A swap waiting to happen can be swapped again, or replaced by a
          # swap of the clip playing now
          swaps = nodes.filter_map { |n|
            # (a ringing-out source swaps the clip it will play again)
            c = n.ring_clip && swapped_clip(n.ring_clip, mapping)
            c ||= n.pending_clip && swapped_clip(n.pending_clip, mapping)
            c ||= swapped_clip(n.clip, mapping)
            [n, c] if c
          }
          raise ArgumentError, "Player #{name.inspect} doesn't play any of the clips being replaced" if swaps.empty?
          swaps
        end

        # Swaps clips at +time+ (applied by the change queue; nil for a
        # stopped player, whose clips change when it resumes).  Returns the
        # number of clip sources that change.
        def swap_now(name, clips, time)
          @mutex.synchronize {
            _, _, nodes = swap_target(name)
            swaps = planned_swaps(name, nodes, clips)
            swaps.each { |n, c| n.swap_clip(c, time: time) }
            swaps.length
          }
        end

        # A short description of what #swap swaps in, for the journal.
        def clip_label(clips)
          case clips
          when Hash then "#{clips.length} pair#{clips.length == 1 ? '' : 's'}"
          when Sequence::Clip then clips.to_s[0, 40]
          when Sequence::Kit then "kit (#{clips.rows.keys.join(', ')})"
          else clips.class.name.split('::').last
          end
        end

        # Converts a Hash of old clips to new clips (or Kits from #grid or
        # Hashes of clips, matched by row name) to a Hash compared by
        # identity.
        def swap_mapping(clips)
          raise ArgumentError, "Pass a Clip, a Kit, or a Hash from old clips to new clips (got #{clips.class})" unless clips.is_a?(Hash) && !clips.empty?

          mapping = {}.compare_by_identity
          clips.each do |old, new|
            old = old.rows if old.is_a?(Sequence::Kit)
            new = new.rows if new.is_a?(Sequence::Kit)

            if old.is_a?(Hash) && new.is_a?(Hash)
              (old.keys & new.keys).each do |k|
                mapping[old[k]] = new[k] if old[k].is_a?(Sequence::Clip) && new[k].is_a?(Sequence::Clip)
              end
            elsif old.is_a?(Sequence::Clip) && new.is_a?(Sequence::Clip)
              mapping[old] = new
            else
              raise ArgumentError, "Clips to swap must be Clips (or Kits or Hashes of Clips), got #{old.class} => #{new.class}"
            end
          end

          mapping
        end

        # A mapping for swapping in Kit +kit+ (see #swap): from each played
        # row's clip (the earliest clip in a source's lineage with a kit
        # row name, so transforms made after it, like a machine's shuffle,
        # are made again from the new row) to the new kit's row of that
        # name, or a silent loop for rows the new kit lacks.
        def kit_swap_mapping(name, nodes, kit, warn: false)
          mapping = {}.compare_by_identity
          played = []
          nodes.each do |n|
            [n.ring_clip, n.pending_clip, n.clip].compact.each do |c|
              root = c.lineage.reverse.find { |x| Sequence::Kit.row_name(x) } or next
              row = Sequence::Kit.row_name(root)
              played << row
              mapping[root] ||= kit.rows.fetch(row) {
                # (a silent row keeps its name, so a later kit brings it back)
                Sequence::Clip.new([], length: 1, loop: true).tap { |q| Sequence::Kit::ROW_NAMES[q] = row }
              }
            end
          end
          raise ArgumentError, "Player #{name.inspect} doesn't play a grid kit's rows; pass old_kit => new_kit" if mapping.empty?

          extra = kit.rows.keys - played.uniq
          if warn && !extra.empty?
            Kernel.warn "swap #{name.inspect}: #{extra.map(&:inspect).join(', ')} #{extra.length == 1 ? 'isn\'t a row' : 'aren\'t rows'} the player plays (no voices for #{extra.length == 1 ? 'it' : 'them'}; bg or launch the kit to build them)"
          end
          mapping
        end

        # Returns a mapping from the clip that every clip source's clip was
        # made from (the nearest common one) to +clip+.
        def auto_swap_mapping(name, nodes, clip)
          lineages = nodes.map { |n| (n.ring_clip || n.pending_clip || n.clip).lineage }
          common = lineages.reduce { |a, b| a.select { |c| b.any? { |x| x.equal?(c) } } }

          if common.empty?
            count = lineages.map(&:last).uniq(&:__id__).length
            raise ArgumentError, "Player #{name.inspect} plays #{count} unrelated clips; pass old => new pairs to choose which to swap"
          end

          { common.first => clip }.compare_by_identity
        end

        # Returns the clip that replaces +clip+ given +mapping+, rebuilding
        # it from a replaced clip it was made from, or nil if it isn't being
        # replaced.
        def swapped_clip(clip, mapping)
          lineage = clip.lineage
          idx = lineage.index { |c| mapping.key?(c) }
          return nil if idx.nil?

          lineage[0...idx].reverse.reduce(mapping[lineage[idx]]) do |new, step|
            step.rederive(new)
          rescue => e
            raise ArgumentError, "Could not rebuild #{step} from #{new}: #{e.message}"
          end
        end
      end
    end
  end
end
