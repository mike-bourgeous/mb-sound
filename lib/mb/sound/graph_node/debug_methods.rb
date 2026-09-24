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
        # See #clear_spies.
        #
        # TODO: accomplish this without monkey patching, and maybe use a module
        # interface rather than a proc (for better rubyprof traces)
        def spy(handle: nil, interval: false, phase: :post, &block)
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
          @handled_spies[handle] << [block, interval, phase, Time.now - (interval || 1), false]

          self
        end

        # Used by #spy.
        private def call_spies(data, phase)
          now = Time.now
          now_nil = data.nil?

          @handled_spies.each do |origin, spies|
            info = origin ? " from #{origin}" : ''

            spies.each_with_index do |spy_info, idx|
              s, interval, spy_phase, last_time, was_nil = spy_info
              next unless spy_phase == phase

              begin
                if !interval || (now - last_time) >= interval || was_nil != now_nil
                  s.call(data)
                  spy_info[-2] = now
                  spy_info[-1] = now_nil
                end
              rescue => e
                warn "Spy #{idx}/#{s}#{info} raised #{MB::U.highlight(e)}"
              end
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

          self
        end

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
