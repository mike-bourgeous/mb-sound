module MB
  module Sound
    module Plan
      # Boundary inputs shared by the regions of several installations
      # (a Synth's lanes): channel-wide controller nodes (Notes#cc, #bend,
      # #pressure, ...; see Notes.control_stream) that every lane reads
      # through its own Tee branches.  Without this, every consumer in every
      # lane reads its branch every block (about 100 branch reads per
      # fm_bass buffer).  With it, the owner (Synth) calls #begin_block
      # before sampling its lanes: each shared source is sampled once and
      # its buffer handed to every region that reads it (Region#gather), and
      # the Tee is skipped, like a region's direct source.
      #
      # A source is shared this way only if every branch of its one Tee is a
      # boundary input of a planned region in these installations (so no
      # unfused node reads a branch, and every reader reads the owner's
      # count; lanes containing resamplers are left out).  Regions that run
      # unfused replay the buffer to their nodes (Region#replay_unfused); if
      # something unusual happens mid-block (a rebuild, a disabled region),
      # #guard! puts the buffer on every branch of every shared source
      # (Tee::Branch#replay) until #end_block, so no reader advances a
      # source twice.  Sharing is recomputed whenever an installation
      # rebuilds.
      class SharedInputs
        # The sources sampled once per block (in order).
        attr_reader :sources

        # Blocks run with shared inputs (for specs and stats).
        attr_reader :blocks

        # +installations+: the lanes' Installations (nil entries for lanes
        # without plans).
        def initialize(installations)
          @installations = installations.compact
          @installations.each { |inst| inst.shared = self }
          @buffers = {}.compare_by_identity
          @views = {}.compare_by_identity # source => GraphNode::FrozenView
          @sources = []
          @branches = []
          @generations = nil
          @active = false
          @guarded = false
          @windows = []
          @blocks = 0
        end

        # The buffers of the current block (source => buffer) while a block
        # is active, else nil (read by Region#gather).
        def buffers
          @active ? @buffers : nil
        end

        # True between #begin_block and #end_block.
        def active?
          @active
        end

        # True if +node+ is sampled here in the current block.
        def shared_node?(node)
          @active && @buffers.key?(node)
        end

        # True if +tee+'s source is shared in the current block (Synth's
        # skipped lanes don't read its branches).
        def shared_tee?(tee)
          @active && @buffers.key?(tee.sources[:input])
        end

        # Samples every shared source once for +count+ samples (refreshing
        # the list first if an installation changed).
        def begin_block(count)
          refresh if @installations.any?(&:stale?) || generations_changed?
          return if @sources.empty?

          @active = true
          @blocks += 1
          bufs = @buffers
          i = 0
          while i < @sources.length
            src = @sources[i]
            buf = src.sample(count)
            # Shared read-only, as the Tee would share it
            buf = (@views[src] ||= GraphNode::FrozenView.new).of(buf) if buf && !buf.frozen?
            bufs[src] = buf
            i += 1
          end
        end

        # Calls the block with #buffers showing +count+ samples from
        # +offset+ of the current block's buffers (read-only views), for a
        # Synth lane rendering part of a block (one woken mid-block or
        # split where it may fall asleep; see Synth#sample_skippable_lane).
        def window(offset, count)
          return yield if !@active || @buffers.empty?

          outer = @buffers
          views = {}.compare_by_identity
          outer.each { |src, buf| views[src] = buf && (offset == 0 && buf.length == count ? buf : buf[offset...(offset + count)].freeze) }
          @buffers = views
          @windows << [outer, views]
          # Replays #guard! left on branches hold the outer buffers: the
          # lane reads this window's part of them instead (protos-1: a lane
          # woken mid-block read a whole block's replay for its 600-sample
          # piece)
          swap_replays(outer, views) if @guarded
          begin
            yield
          ensure
            swap_replays(views, outer) if @guarded
            @windows.pop
            @buffers = outer
          end
        end

        # Ends the block (clears any replays #guard! left unread).
        def end_block
          return unless @active

          if @guarded
            @branches.each { |list| list.each { |b| b.replay = nil } }
            @guarded = false
          end
          @active = false
        end

        # Puts the current block's buffer on every branch of every shared
        # source, so any reader this block (a region rebuilt or disabled
        # mid-block, an unfused node) reads it without sampling the source
        # again.  Called by Region and Installation when a block leaves the
        # usual path.
        def guard!
          return unless @active && !@guarded

          @guarded = true
          # (whole-block buffers, so lanes read after this window get theirs;
          # the open windows show their parts, see #window)
          base = @windows.empty? ? @buffers : @windows[0][0]
          @sources.each_with_index do |src, i|
            buf = base[src]
            @branches[i].each { |b| b.replay = buf }
          end
          @windows.each { |outer, views| swap_replays(outer, views) }
        end

        # Replaces branch replays that are buffers of +from+ (source =>
        # buffer) with the same source's buffer in +to+.
        def swap_replays(from, to)
          @sources.each_with_index do |src, i|
            f = from[src]
            next if f.nil?

            t = to[src]
            @branches[i].each { |b| b.replay = t if b.replay.equal?(f) }
          end
        end

        # Recomputes which sources are shared (see the class description).
        def refresh
          @buffers.clear
          @views.clear
          @sources = []
          @branches = []

          handles = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          insts_of = Hash.new { |h, k| h[k] = {}.compare_by_identity }.compare_by_identity
          usable = @installations.reject { |inst| inst.resamples? }
          usable.each do |inst|
            inst.rebuild if inst.stale?
            inst.regions.each do |r|
              next if r.disabled
              prog = r.program || r.precompile
              next unless prog

              prog.inputs.each do |op|
                op.handles.each { |h| handles[op.source] << h unless handles[op.source].any? { |x| x.equal?(h) } }
                insts_of[op.source][inst] = true
              end
            end
          end

          handles.each do |src, list|
            # Several installations (lanes) read it: channel-wide nodes.
            # A lane's own nodes stay with the lane (skipped lanes advance
            # them themselves; see Synth#skip_lane)
            next if insts_of[src].length < 2

            tees = list.map { |h| h.is_a?(GraphNode::Tee::Branch) ? h.owner_tee : nil }.uniq
            next unless tees.length == 1 && tees[0]

            tee = tees[0]
            next unless tee.sources[:input].equal?(src)
            # Unread branches (Installation#live_branches) don't count
            live = @installations[0].live_branches(tee)
            next unless live.length == list.length && live.all? { |b| list.any? { |h| h.equal?(b) } }

            @sources << src
            @branches << live.dup
          end

          @generations = @installations.map(&:generation)
          self
        end

        private

        def generations_changed?
          return true if @generations.nil?

          i = 0
          while i < @installations.length
            return true unless @installations[i].generation == @generations[i]
            i += 1
          end
          false
        end
      end
    end
  end
end
