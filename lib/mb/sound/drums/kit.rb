module MB
  module Sound
    module Drums
      # A drum machine kit: the mixed sum of its Voices (see Drums).  Ends
      # when every voice has ended (see Voice; never for looping clips or
      # live MIDI).  Index it by voice name for single voices, e.g. to
      # process the kick separately:
      #
      #     kit = tr808(grid(16, kick: 'x...x...', hat: 'x.x.x.x.').loop)
      #     kit[:kick]     # the kick Voice (also part of the mix)
      #     kit.voices     # { kick: Voice, closed_hat: Voice }
      class Kit
        include GraphNode
        node_traits memory: :short

        # The machine name (e.g. :tr808).
        attr_reader :machine

        # The voices by name (a frozen Hash).
        attr_reader :voices

        # +:clip_notes+ (the note numbers its voices play, when it was built
        # for a clip's notes) and +:velocity_curve+ (the curve chosen from
        # its source, nil if given) describe the clips it can take in a
        # swap (see #plays_clip?).
        # +:flams+ is true if the kit plays flam marks (see Drums.flams?).
        # +:silent+ names voices that play but aren't mixed (trigger voices that
        # sidechains read; see Machine::Builder#voice).
        def initialize(voices, machine:, clip_notes: nil, velocity_curve: nil, flams: false, silent: [], sample_rate: 48000)
          raise ArgumentError, 'A drum kit needs at least one voice' if voices.empty?

          @clip_notes = clip_notes&.uniq&.freeze
          @auto_curve = velocity_curve
          @flams = !!flams

          @voices = voices.dup.freeze
          @samplers = @voices.transform_values(&:get_sampler)
          @silent = silent.map(&:to_sym).freeze
          unknown = @silent - @voices.keys
          raise ArgumentError, "No voice #{unknown.first.inspect} to make silent" unless unknown.empty?
          @machine = machine
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = "#{machine} kit"
        end

        # The voice named +name+.
        def [](name)
          @voices.fetch(name) { raise KeyError, "No #{@machine} voice #{name.inspect} in this kit (voices: #{@voices.keys.map(&:inspect).join(', ')})" }
        end

        # The voice names.
        def names
          @voices.keys
        end

        # The silent voices' names (played, never mixed).
        attr_reader :silent

        def sample(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          BufferHelper.zero(@buf)

          any = false
          @samplers.each do |name, s|
            data = s.sample(count)
            next if data.nil? || data.empty?
            next any = true if @silent.include?(name) # (played for its readers, never mixed)

            any = true
            if Kernels.add_at(@buf, 0, data, data.length, nil)
              # (allocation-free; else the Numo mirror below)
            elsif data.length == count
              @buf.inplace + data
            else
              @buf[0...data.length] = @buf[0...data.length] + data
            end
          end

          any ? @buf : nil
        end

        # True if swapping +clip+ (a Sequence::Clip) into this kit's clip
        # source plays it as a kit built for +clip+ would: a kit built for
        # a clip has only the voices that clip plays, and a kit chooses its
        # velocity curve from its source (a performed clip plays like live
        # MIDI; see Drums.velocity_curve).  Arrangement tracks build the
        # patch again for a clip a playing kit can't take.
        def plays_clip?(clip)
          return false if @auto_curve && Drums.velocity_curve(clip) != @auto_curve
          return false if !@flams && Drums.flams?(clip)
          return true if @clip_notes.nil?

          clip.values.all? { |v| @clip_notes.any? { |n| v == n } }
        end

        # True once every voice has ended.
        def ended?
          @voices.each_value.all?(&:ended?)
        end

        attr_reader :sample_rate

        def sample_rate=(rate)
          @voices.each_value { |v| v.sample_rate = rate }
          @sample_rate = rate.to_f
          self
        end

        def sources
          @samplers.dup
        end

        # Every voice is a main input (see GraphNode::Traversable#port_role).
        def port_role(name)
          :main
        end

        def to_s
          "#{@machine} kit (#{@voices.keys.join(', ')})"
        end
      end
    end
  end
end
