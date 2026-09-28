module MB
  module Sound
    module GraphNode
      # Implementation of a wavetable waveshaper/synthesizer based on a wave
      # table stored as a 2D Numo::NArray.
      #
      # See bin/make_wavetable.rb.
      # See MB::Sound::Wavetable.
      # See MB::Sound::GraphNode#wavetable.
      class Wavetable
        include GraphNode
        include GraphNode::SampleRateHelper

        # Valid values for the constructor's :wrap parameter.
        WRAP_MODES = [
          :wrap,
          :bounce,
          :clamp,
          :zero
        ]

        # Valid values for the constructor's :lookup parameter.
        LOOKUP_MODES = [
          :linear,
          :cubic
        ]

        # The 2D Numo::NArray wavetable data used for sampling.
        attr_reader :table

        # The interpolation mode -- :cubic or :linear
        attr_accessor :lookup

        # The wrapping mode -- :wrap, :clamp, :bounce, or :zero
        attr_accessor :wrap

        # Creates a new wavetable node.
        #
        # The output of the MIDI value node for +:wrap+ will be scaled from its
        # original range to cover the range of wrapping modes, without
        # blending.
        #
        # +:wavetable+ - A 2D Numo::NArray with time as columns and waves as
        #                rows, the filename of a previously saved wavetable, or
        #                a Hash of args to MB::Sound::Wavetable.load_wavetable.
        # +:number+ - A GraphNode to control the wave number (e.g. `3.constant`).
        # +:phase+ - A GraphNode to control the wave phase (e.g. `120.hz.ramp.at(1)`).
        # +:lookup+ - Interpolation mode (:cubic or :linear).
        # +:wrap+ - Wrapping mode (:wrap, :clamp, :bounce, :zero).  This can
        #           also be a MIDI value node to allow changing modes on the fly.
        def initialize(wavetable:, number:, phase:, sample_rate:, lookup:, wrap:)
          raise 'Number must be a GraphNode' unless number.is_a?(GraphNode)
          raise 'Phase must be a GraphNode' unless phase.is_a?(GraphNode)
          raise 'Lookup mode must be :linear or :cubic' unless LOOKUP_MODES.include?(lookup)
          unless WRAP_MODES.include?(wrap) || wrap.is_a?(MB::Sound::GraphNode::MidiDsl::MidiValue)
            raise 'Wrapping mode must be a symbol or a MIDI node'
          end

          case wavetable
          when Hash
            filename = wavetable.fetch(:wavetable)
            args = wavetable.reject { |k, _| k == :wavetable }
            wavetable = MB::Sound::Wavetable.load_wavetable(filename, **args)

          when String
            wavetable = MB::Sound::Wavetable.load_wavetable(wavetable)

          else
            unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2
              raise 'Wavetable must be a 2D NArray, Hash of load_wavetable arguments, or a wavetable filename'
            end
          end

          @table = wavetable
          @number = number
          @phase = phase
          @sample_rate = sample_rate
          @lookup = lookup
          @wrap = wrap
        end

        # The inputs to this node for wave number and wave phase.
        def sources
          {
            number: @number,
            phase: @phase,
          }
        end

        # Returns +count+ samples based on a wavetable lookup using the wave
        # number and phase from upstream graph sources given to the constructor.
        def sample(count)
          rho = @number.sample(count)
          phi = @phase.sample(count)
          return nil if rho.nil? || phi.nil? || rho.empty? || phi.empty?

          rho = MB::M.zpad(rho, count) if rho.length < count
          phi = MB::M.zpad(phi, count) if phi.length < count

          case @wrap
          when Symbol
            wrap = @wrap

          else
            # MIDI-controlled wrapping mode
            # TODO: allow the value range to select a subset of wrapping modes?
            # TODO: allow any graph node and treat a range of 0..1 as the index range, with wrapping?
            data = @wrap.sample(count)
            return nil if data.nil? || data.empty?
            index = MB::M.scale(data[-1], @wrap.range || (0..1), 0..WRAP_MODES.length).floor
            index = WRAP_MODES.length - 1 if index >= WRAP_MODES.length
            wrap = WRAP_MODES[index]
          end

          ::MB::Sound::Wavetable.wavetable_lookup(wavetable: @table, number: rho, phase: phi, lookup: @lookup, wrap: wrap)
        end
      end
    end
  end
end
