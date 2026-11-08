module MB
  module Sound
    module GraphNode
      # How far a graph reads ahead of its output from span-fed sources:
      # nodes fed by the Session one buffer at a time, which can't give
      # frames past the buffer being rendered (a bus or master chain's
      # MixSource channels, bus taps).  Nodes that read their sources ahead
      # of their output say how far with #read_ahead (frames at their
      # source's rate, at any buffer size: a #resample's filter lookahead,
      # a BufferAdapter's block), and the source starts that many frames
      # late (MixSource#read_ahead), so every read finds written frames.
      #
      # Before fix-bus-resample-1 a MixSource handed every whole-buffer read
      # the same buffer, so `bus(:x) { |sig| sig.resample(96000).resample(48000) }`
      # played its first buffer three times and the bus two buffers late
      # (1600 frames at 800-frame buffers, 734 at 367).
      module ReadAhead
        # The most frames at +rate+ that any path from +roots+ (nodes or
        # Arrays of them) down to one of +leaves+ (span-fed nodes; a
        # multi-output node stands for its outputs) reads ahead: the sum of
        # #read_ahead along the path, converted through each node's source
        # rate.  Paths that don't reach a leaf don't count.  0 if none
        # reads ahead.
        def self.frames(roots, leaves, rate)
          leafset = {}.compare_by_identity
          Array(leaves).each do |l|
            leafset[l] = true
            l.outputs.each { |o| leafset[o] = true } if l.respond_to?(:outputs)
          end

          memo = {}.compare_by_identity
          open = {}.compare_by_identity
          walk = nil
          walk = ->(n) {
            return memo[n] if memo.key?(n)
            return 0.0 if leafset[n]
            return nil if open[n]

            open[n] = true
            # (an oversample region's rates are applied on first use; its
            # resamplers' ratios decide their read-ahead)
            n.apply_oversample if n.is_a?(Resample) && n.oversample_pending
            own = n.respond_to?(:read_ahead) ? n.read_ahead.to_i : 0
            best = nil
            GraphNode.graph_source_list(n, true).each do |src|
              w = walk.(src)
              next if w.nil?

              if own > 0
                r = src.respond_to?(:sample_rate) && src.sample_rate ? src.sample_rate.to_f : rate.to_f
                w += own / r
              end
              best = w if best.nil? || w > best
            end
            open.delete(n)
            memo[n] = best
          }

          seconds = Array(roots).flatten.map { |r| walk.(GraphNode.graph_key(r, true)) }.compact.max
          seconds ? (seconds * rate.to_f - 1e-9).ceil : 0
        end
      end
    end
  end
end
