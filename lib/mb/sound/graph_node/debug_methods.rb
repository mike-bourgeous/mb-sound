module MB
  module Sound
    module GraphNode
      # Methods for observing the data flowing through a graph node.  Included
      # in GraphNode.
      module DebugMethods
        # Calls the given block with each sample buffer whenever #sample is
        # called.  Returns self to allow chaining, but this method is also useful
        # after a chain has been constructed for spying on a specific object's
        # output.
        #
        # This is like adding a trace point to tap into a circuit, and allows
        # intermediate values in a signal graph to be plotted or saved.
        #
        # The block should not modify the buffer, and should not retain a
        # reference to the buffer.  Instead, the buffer may be copied to an
        # existing buffer using Numo::NArray#[]=:
        #
        #     block_buf[] = spy_buf
        #
        # You can specify a minimum +:interval+ in seconds to reduce CPU load,
        # and your spy won't be called until at least that amount of time has
        # elapsed, or the value spied changes to/from nil.
        #
        # If you'll need to remove specific spies later, pass a +:handle+.  This
        # may be an object instance, a Symbol, etc.
        #
        # The +:phase+ argument may be :pre to receive the number of samples
        # before a node executes, or :post to receive a copy of the data the node
        # returns.
        #
        # With +snapshot: true+ (for taps that hand buffers to another
        # thread, e.g. a UI painter), a :post spy gets a frozen copy of each
        # buffer it may keep: `buf.dup.freeze`, the same NArray class the
        # node returns (Numo::SFloat for most nodes; complex nodes give
        # SComplex/DComplex), one buffer long, shared by every snapshot spy
        # of the node for that buffer; nil when the node ends.  It carries
        # no frame number (spy from inside a Session render and read
        # Session.span for the frame; Session taps with frames are phase V).  Spies on nodes fused into a plan
        # get their buffers from Plan::Op::Tap the same way.  Spies run on
        # the render thread: queue snapshots there, draw elsewhere.
        #
        # See #clear_spies.
        #
        # TODO: accomplish this without monkey patching, and maybe use a module
        # interface rather than a proc (for better rubyprof traces)
        def spy(handle: nil, interval: false, phase: :post, snapshot: false, &block)
          @handled_spies ||= nil

          if @handled_spies.nil?
            @handled_spies = {}

            class << self
              def sample(count)
                call_spies(count, :pre)

                super(count).tap { |buf|
                  MB::M.with_inplace(buf, false) do |data|
                    call_spies(data, :post)
                  end
                }
              end
            end
          end

          @handled_spies[handle] ||= []
          @handled_spies[handle] << [block, interval, phase, Time.now - (interval || 1), false, snapshot]

          # A spied node inside a plan gets a tap (see Plan::Op::Tap)
          Plan.changed(self)

          self
        end

        # Used by #spy.  Runs every buffer (twice: :pre and :post), so it
        # allocates nothing for spies without an interval (no Time, no
        # label String, no Enumerator; dropouts-2: ~1900 objects a second
        # from a `duck(:drums, only: :kick)` spy).
        private def call_spies(data, phase)
          now = nil
          now_nil = data.nil?
          frozen = nil

          @handled_spies.each do |origin, spies|
            idx = 0
            while idx < spies.length
              spy_info = spies[idx]
              s, interval, spy_phase, last_time, was_nil, snapshot = spy_info
              now ||= Time.now if interval # (once per call, as before)
              if spy_phase == phase
                begin
                  if !interval || (now - last_time) >= interval || was_nil != now_nil
                    if snapshot && phase == :post && data.respond_to?(:dup)
                      frozen ||= data.dup.freeze
                      s.call(frozen)
                    else
                      s.call(data)
                    end
                    spy_info[3] = now if interval
                    spy_info[4] = now_nil
                  end
                rescue => e
                  warn "Spy #{idx}/#{s}#{origin ? " from #{origin}" : ''} raised #{MB::U.highlight(e)}"
                end
              end
              idx += 1
            end
          end
        end

        # Clears any spies attached to this graph node (see #spy), or just spies
        # associated with the given +:handle+.
        def clear_spies(handle: nil)
          @handled_spies ||= nil

          if handle
            if @handled_spies && @handled_spies.include?(handle)
              @handled_spies[handle].clear
              @handled_spies.delete(handle)
            end
          else
            @handled_spies&.clear
          end
          Plan.changed(self)

          self
        end

        # Passes this node through a live ITU-R BS.1770 loudness meter (see
        # LoudnessMeter), returned as a one-channel bundle whose #momentary,
        # #short_term, #integrated, #range, and #true_peak read the loudness
        # so far.  Bundles measure all of their channels together (see
        # Channels#loudness_meter).
        #
        # Example (bin/sound.rb):
        #     m = 220.hz.saw.at(-20.db).loudness_meter
        #     bg m
        #     m.short_term   # => LUFS of the last 3 s
        def loudness_meter(weights: nil, true_peak: true)
          LoudnessMeter.new(outputs, weights: weights, true_peak: true_peak)
        end
        alias lufs_meter loudness_meter

        # Logs the first, last, min, max, and mean values for each buffer from
        # this node.
        def debug
          debug_iter = 0
          spy { |v|
            if v
              s = "f/l: #{v[0]}/#{v[-1]} m/m: #{v.minmax} avg: #{v.mean}"
            else
              s = 'nil'
            end

            puts "DEBUG: #{__id__}/#{self} frame #{debug_iter}: #{s}"

            debug_iter += 1
          }
        end
      end
    end
  end
end
