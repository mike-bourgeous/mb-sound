module MB
  module Sound
    module GraphNode
      # Methods for connecting graph nodes to inputs, branches, other nodes,
      # and custom processing blocks.  Included in GraphNode.
      module RoutingMethods
        # Creates and returns an input object that reads from this node's #sample
        # method whenever the I/O's #read method is called.
        #
        # See MB::Sound::GraphNode::GraphNodeArrayMixin#as_input for a method of
        # combining multiple nodes into a readable input.
        def as_input(num_channels = 1, buffer_size: nil)
          MB::Sound::GraphNodeInput.new(self, channels: num_channels, buffer_size: buffer_size)
        end

        # Returns +n+ (default 2) fan-out readers for creating branching signal
        # graphs.  This is useful because the #sample method can only be called
        # once per frame because it updates the internal state of signal nodes.
        # Each fan-out reader gets a copy of the input buffer, so downstream
        # nodes can call #sample (once per cycle!) on their branch of the tee and
        # modify the resulting buffer without affecting parallel branches of the
        # graph.
        #
        # Note that teeing should not be necessary in most cases, as most graph
        # nodes will call #get_sampler to get an implicit tee now.
        #
        # Example (for bin/sound.rb):
        #     # AM and tremolo added together for some reason
        #     a, b = 120.hz.tee ; nil
        #     c = a * 150.hz.at(0.5..1) + b * 0.5.hz.at(0.25..1) ; nil
        #     play c
        def tee(n = 2)
          Tee.new(get_sampler, n).branches
        end

        # Creates and returns a tee branch from this node.  This is used by
        # consumers of upstream graph nodes like Tone, SampleWrapper, etc. to
        # allow implicit branching of node outputs.
        #
        # If you need to call this outside of mb-sound internal code or your own
        # custom GraphNode implementations, that's _probably_ a bug in mb-sound.
        def get_sampler
          # TODO: maybe rename to #get_branch to match Tee's naming??
          # TODO: find and fix places where branches get abandoned (e.g.
          # bin/flanger.rb) instead of ignoring late readers in
          # circular_buffer.rb
          @internal_tee ||= Tee.new(self, 0)
          @internal_tee.add_branch
        end

        # Adds a Ruby block to a processing chain.  The block will be called with
        # a Numo::NArray containing samples to be modified.  Note that this can
        # be very slow compared to the built-in algorithms implemented in C.
        def proc(sources = {}, type_name: nil, &block)
          ProcNode.new(self, extra_sources: sources, sample_rate: self.sample_rate, type_name: type_name, &block)
        end

        # Marks this node's output as a length in samples (Length::Samples),
        # e.g. for a delay time that changes every sample:
        # `sig.delay(lfo.at(10..20).samples)`.
        def samples
          Length::Samples.new(self)
        end

        # Marks this node's output as a length in seconds (Length::Seconds).
        # Plain nodes are already seconds where a method counts in seconds.
        def seconds
          Length::Seconds.new(self)
        end

        # If this node (or its inputs) have a finite length of audio data
        # available (e.g. a sound file), then when they run out of data the given
        # +sources+ (other graph nodes that respond to :sample) will be played
        # after this node finishes.
        def and_then(*sources)
          raise 'No sources were given' if sources.empty?
          MB::Sound::GraphNode::NodeSequence.new([self, *sources])
        end

        # Returns a node that plays this node for +length+ (seconds, or a
        # musical Duration like `2.bars` that follows the tempo), then ends,
        # cutting it off (see TimeLimit).  Oscillators play forever, so this
        # gives a sound a fixed length; for a musical ending, multiply by an
        # envelope instead (see #adsr).
        #
        # Example (bin/sound.rb):
        #     play 220.hz.ramp.at(-6.db).until(2)
        #     bg 220.hz.ramp.at(-6.db).until(2.bars)
        def until(length)
          MB::Sound::GraphNode::TimeLimit.new(self, length)
        end

        # Returns a node that plays this node, then silence forever once it
        # ends, so effects after it can ring out (see Ringdown).  On a
        # multichannel node, each channel gets its own Ringdown.
        def ringdown
          MB::Sound::GraphNode::Ringdown.new(self)
        end

        # Calls #sample with +count+ requested samples +times+ times,
        # concatenating the results into a single array.
        def multi_sample(count, times)
          raise "Count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
          raise "Times must be a positive Integer (got #{count.inspect})" unless times.is_a?(Integer) && times > 0

          ret = nil
          endidx = 0

          for i in 0...times
            idx = endidx

            d = sample(count)
            break if d.nil? || d.empty?

            ret ||= d.class.zeros(count * times)

            endidx = idx + d.length
            ret[idx...endidx] = d
          end

          ret[0...endidx] if ret
        end

        # Appends a BufferAdapter to the graph with this node as its upstream
        # source, using the given +length+ as the upstream frame size.  When
        # downstream nodes sample the adapter, the adapter will sample the
        # upstream node in +length+-sized chunks.  This allows running a node
        # graph with a shorter internal buffer size than the sound card input or
        # output buffer size, for example.  Plain numbers are samples; other
        # lengths (e.g. `5.ms`) are rounded to samples at this node's rate.
        def with_buffer(length)
          length = MB::Sound::Length.samples(length, sample_rate: sample_rate).round if length.is_a?(MB::Sound::Length)
          MB::Sound::GraphNode::BufferAdapter.new(upstream: self, upstream_count: length)
        end
      end
    end
  end
end
