module MB
  module Sound
    module GraphNode
      # Sample and hold: outputs the value of its +source+ at each rising edge
      # of its +trigger+ (a sample > 0 after one <= 0, like Envelope
      # triggers), holding it until the next edge.  Without a source it holds
      # seeded random values instead (uniform over +range+, default -1..1),
      # the classic random "noise" LFO; the random numbers come from a Random
      # seeded with +seed+, or a sub-seed drawn from the root generator when
      # the node is made (see MB::Sound.seed), so renders repeat.
      #
      # Before the first edge the output is the source's first sample (or a
      # first random value).  The trigger is often a square LFO, whose
      # rising edges come once per cycle (see Notes#lfo's :noise shape).
      # Ends when the source or trigger ends.
      #
      #     play 110.hz.saw.filter(:lowpass, cutoff: (8.hz.lfo.square.sample_hold * 0.4 + 1) * 800, quality: 3)
      #     play 220.hz.sine.sample_hold(2000.hz.square)   # a rough decimator
      class SampleHold
        include GraphNode
        include SampleRateHelper

        # The source (a sampler branch), or nil for random values.
        attr_reader :source

        # The trigger node (a sampler branch).
        attr_reader :trigger

        # The random range (random mode).
        attr_reader :range

        def initialize(source, trigger, range: -1.0..1.0, seed: nil, sample_rate: nil)
          raise ArgumentError, "Trigger must be a graph node (got #{trigger.inspect})" unless trigger.respond_to?(:sample)
          raise ArgumentError, "Source must be nil or a graph node (got #{source.inspect})" unless source.nil? || source.respond_to?(:sample)

          @source = source&.get_sampler
          @trigger = trigger.get_sampler
          @range = range.begin.to_f..range.end.to_f
          @random = source.nil? ? Random.new(seed.nil? ? MB::Sound.next_seed : Integer(seed)) : nil
          @sample_rate = (sample_rate || trigger.sample_rate).to_f
          @held = nil
          @prev = 0.0
          @buf = nil
          @node_type_name = source ? 'Sample & Hold' : 'Random Hold'
        end

        def sample(count)
          trig = @trigger.sample(count)
          return nil if trig.nil? || trig.empty?

          data = nil
          if @source
            data = @source.sample(count)
            return nil if data.nil? || data.empty?
            n = MB::M.min(trig.length, data.length)
          else
            n = trig.length
          end

          @held ||= data ? data[0].to_f : draw

          # Rising edges: sample i > 0 after i - 1 <= 0
          pos = trig[0...n].gt(0)
          prev = Numo::Bit.zeros(n)
          prev[0] = @prev > 0 ? 1 : 0
          prev[1..] = pos[0...(n - 1)] if n > 1
          edges = (pos & ~prev).where
          @prev = trig[n - 1].to_f

          @buf = Numo::SFloat.zeros(n) if @buf.nil? || @buf.length != n
          start = 0
          edges.each do |i|
            @buf[start...i] = @held if i > start
            @held = data ? data[i].to_f : draw
            start = i
          end
          @buf[start...n] = @held

          @buf
        end

        def sources
          @source ? { input: @source, trigger: @trigger } : { trigger: @trigger }
        end

        def to_s
          @source ? 'Sample & Hold' : "Random Hold #{MB::M.sigfigs(@range.begin, 3)}..#{MB::M.sigfigs(@range.end, 3)}"
        end

        private

        def draw
          @range.begin + (@range.end - @range.begin) * @random.rand
        end
      end
    end
  end
end
