module MB
  module Sound
    module GraphNode
      # Reads a cycle-mode MB::Sound::Wavetable at a phase from any signal
      # (in cycles: 0...1 is one cycle), for exotic phase sources, or as a
      # waveshaper (wrap mode :shape: -1..1 spread across the whole cycle,
      # clamped at the ends).  Oscillators are better made with
      # Tone#wavetable (e.g. `440.hz.wavetable(table)`), which also gets
      # sync, phase warps, and resets.  See GraphNode#phase_table and
      # #waveshape.
      #
      # Levels (see MB::Sound::Wavetable) are picked from the phase's speed:
      # an +increment+ node (cycles per sample), the +increment+ port of a
      # phasor Tone given as the phase (e.g. `100.hz.phasor`), or else the
      # change of the phase from sample to sample (wrapped to -0.5..0.5 for
      # :wrap, halved for :shape), its peak held for about a buffer
      # (FastWavetable.lookup), so a fast-moving shaper input reads duller
      # levels instead of aliasing.  +increment: false+ always reads the
      # brightest level.
      class Wavetable
        include GraphNode
        include GraphNode::SampleRateHelper

        # Valid values for the constructor's +:wrap+ parameter (see
        # MB::Sound::Wavetable::WRAP_MODES).
        WRAP_MODES = MB::Sound::Wavetable::WRAP_MODES

        # The modes a +:wrap+ node chooses among (not :shape, which reads its
        # input differently).
        NODE_WRAP_MODES = (WRAP_MODES - [:shape]).freeze

        # The MB::Sound::Wavetable read by this node.
        attr_reader :table

        # The interpolation (see MB::Sound::Wavetable::INTERPOLATIONS), or nil
        # for the table's default.
        attr_reader :interpolation

        # The wrapping mode (a Symbol, or a graph node).
        attr_reader :wrap

        # +:table+ - Anything MB::Sound::Wavetable.[] accepts (a Wavetable, a
        #            library name, a filename, samples).
        # +:phase+ - A graph node with the phase in cycles.
        # +:scan+ - The position across the table's frames (0..1), a number or
        #           a graph node.
        # +:increment+ - A graph node with the phase increment per sample in
        #                cycles for picking levels, nil to estimate it from
        #                the phase, or false for the brightest level.
        # +:interpolation+ - See MB::Sound::Wavetable (nil for the table's
        #                    default).
        # +:wrap+ - What phases outside 0...1 read: :wrap (around), :bounce
        #           (back and forth), :clamp (the ends), or :zero (silence);
        #           or :shape, for a phase from -1 to 1 spread across the
        #           cycle and clamped (see GraphNode#waveshape).
        #           A graph node picks the mode from its output (the last
        #           sample of each buffer), its range (a MIDI controller's
        #           MIDI::ControlSpec range, e.g. from Notes#cc, else 0..1)
        #           scaled to cover the modes.
        def initialize(table:, phase:, sample_rate:, scan: 0, increment: nil, interpolation: nil, wrap: :wrap)
          raise ArgumentError, 'Phase must be a graph node' unless phase.respond_to?(:sample)
          unless WRAP_MODES.include?(wrap) || wrap.respond_to?(:sample)
            raise ArgumentError, "Wrapping mode must be one of #{WRAP_MODES.join(', ')} or a graph node"
          end
          unless scan.is_a?(Numeric) || scan.respond_to?(:sample)
            raise ArgumentError, 'Scan must be a number or a graph node'
          end

          @table = MB::Sound::Wavetable[table]
          raise ArgumentError, "#{@table} is a sample-mode table; play it with a Tone (e.g. C4.wavetable(table))" unless @table.mode == :cycle

          @table.interpolation_code(interpolation) # check it
          @interpolation = interpolation
          @phase = phase.get_sampler
          @increment = increment.respond_to?(:get_sampler) ? increment.get_sampler : increment
          raise ArgumentError, 'Increment must be nil, false, or a graph node' unless @increment.nil? || @increment == false || @increment.respond_to?(:sample)

          @lstate = [0.0, 0, 0.0, 0]
          @scan = scan.respond_to?(:get_sampler) ? scan.get_sampler : scan
          @sample_rate = sample_rate
          @wrap = wrap.respond_to?(:get_sampler) ? wrap.get_sampler : wrap
          @wrap_range = wrap.respond_to?(:spec) && wrap.spec.respond_to?(:range) ? wrap.spec.range : 0..1
          @buf = nil
        end

        # The inputs to this node: the phase, the scan position, the
        # increment, and the wrapping mode (if they are graph nodes).
        def sources
          {
            phase: @phase,
            scan: (@scan if @scan.respond_to?(:sample)),
            increment: (@increment if @increment.respond_to?(:sample)),
            wrap: (@wrap if @wrap.respond_to?(:sample)),
          }.compact
        end

        # Returns +count+ samples of the table at the phase input's phases.
        # Ends when the phase ends.
        def sample(count)
          phi = @phase.sample(count)
          return nil if phi.nil? || phi.empty?

          count = phi.length

          inc = @increment
          if inc.respond_to?(:sample)
            inc = inc.sample(count)
            inc = MB::M.zpad(inc, count) if inc && inc.length < count
          end

          scan = @scan
          if scan.respond_to?(:sample)
            scan = scan.sample(count)
            return nil if scan.nil? || scan.empty?

            scan = MB::M.zpad(scan, count) if scan.length < count
          end

          case @wrap
          when Symbol
            wrap = @wrap

          else
            # Node-controlled wrapping mode
            data = @wrap.sample(count)
            return nil if data.nil? || data.empty?

            modes = NODE_WRAP_MODES
            index = MB::M.scale(data[-1], @wrap_range, 0..modes.length).floor
            index = 0 if index < 0
            index = modes.length - 1 if index >= modes.length
            wrap = modes[index]
          end

          buf_class = @table.complex? ? Numo::SComplex : Numo::SFloat
          @buf = buf_class.zeros(count) if @buf.nil? || @buf.length != count
          @table.lookup(@buf.inplace!, phi, inc, scan, @interpolation, @sample_rate, wrap, @lstate).not_inplace!
        end
      end
    end
  end
end
