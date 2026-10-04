module MB
  module Sound
    class Notes
      # An Envelope made through a Notes instance (Notes#env, #amp_env,
      # #fm_env, #filter_env): its gate, trigger, velocity, and choke inputs
      # come from the Notes, it registers with the Notes for Notes#idle?,
      # and with #gm (on by default) its attack, decay, and release times
      # are multiplied by the GM2 sound controllers CC 73 (Notes#attack_time),
      # CC 75 (#decay_time), and CC 72 (#release_time): x1/8 at 0, x1 at 64,
      # x8 at 127, exponentially, read through nodes so knobs act at once.
      #
      # Times given as numbers or lengths in seconds are scaled as they are;
      # musical lengths (Durations) and sample counts are converted to
      # seconds when set, so with #gm they no longer follow the tempo.  Times
      # given as nodes are multiplied by the factor nodes.
      class NoteEnvelope < MB::Sound::Envelope
        # The Notes method for each segment's GM2 time controller.
        GM_TIMES = { attack: :attack_time, decay: :decay_time, release: :release_time }.freeze

        # The Notes instance this envelope belongs to.
        attr_reader :notes

        # Takes the Envelope options, plus the +:notes+ it belongs to and
        # whether +:gm+ scaling is on (see the class description).
        def initialize(notes:, gm: true, **options)
          @notes = notes
          @gm = false
          @base_times = {}
          @gm_nodes = {}
          super(**options)
          gm(gm)
        end

        # Turns GM2 time scaling on or off (see the class description).
        # Returns self.
        def gm(enabled = true)
          enabled = !!enabled
          return self if enabled == @gm

          @gm = enabled
          GM_TIMES.each_key { |seg| public_send(:"#{seg}=", @base_times[seg]) }
          self
        end

        # True if GM2 time scaling is on (see #gm).
        def gm?
          @gm
        end

        # The attack, decay, and release times as given, before GM2 scaling.
        def base_times
          @base_times.dup
        end

        def attack=(time)
          super(gm_time(:attack, time))
        end
        alias attack_time= attack=

        def decay=(time)
          super(gm_time(:decay, time))
        end
        alias decay_time= decay=

        def release=(time)
          super(gm_time(:release, time))
        end
        alias release_time= release=

        private

        # Records +time+ as the base time of +segment+ and returns it scaled
        # if #gm is on.  Lets go of the scaling node made for the previous
        # time, if any.
        def gm_time(segment, time)
          @base_times[segment] = time
          drop_gm_node(segment)
          return time unless @gm

          factor = @notes.public_send(GM_TIMES.fetch(segment))
          node = case time
                 when Numeric
                   factor * time.to_f
                 when Length
                   return time if time.respond_to?(:node) && time.node # node lengths stay unscaled
                   factor * Length.seconds(time, sample_rate: @sample_rate)
                 else
                   return time unless time.respond_to?(:sample)
                   time * factor
                 end

          @gm_nodes[segment] = node
          node
        end

        # Destroys the Tee branches of a scaling node that is no longer used
        # (see #gm_time), so the shared controller's Tee stops feeding it.
        def drop_gm_node(segment)
          node = @gm_nodes.delete(segment)
          return unless node

          node.sources.each_value do |src|
            src.destroy if src.is_a?(GraphNode::Tee::Branch)
          end
        end
      end
    end
  end
end
