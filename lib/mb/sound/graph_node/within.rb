module MB
  module Sound
    module GraphNode
      # A node of frequencies (Hz) moved into a note or frequency range by
      # whole octaves, sample by sample, keeping each frequency's pitch
      # class (GraphNode#within; the shared rules are MB::Sound::OctaveFold's):
      # a frequency already in the range stays, one below moves up by the
      # fewest octaves that reach it, one above moves down.  For notes as
      # frequencies, e.g. an LFO rate that follows the melody in a
      # sub-audio register (`phaser(rate: notes.freq.within(2.hz..8.hz))`),
      # or a bass that doubles the lead's notes in its own octave.
      #
      # Constant inputs come out exact (powers of two only).  A moving
      # input jumps by exactly one octave on the sample where it crosses an
      # edge (a glide up through an inclusive top edge drops an octave on
      # the first sample past it, a glide down through the bottom edge
      # rises one), so an oscillator it drives stays phase-continuous but
      # changes octave at once; chain `.smooth(20.ms)` to glide the jump
      # instead.  A note at an edge (its frequency as `.freq` computes it)
      # counts as inside: the edges are rounded to float32 like the signal.
      #
      # Note ends of the range follow the session Tuning, read each buffer;
      # zero stays zero, negative frequencies fold their size and keep
      # their sign, NaN and infinities pass through.  Kernel
      # FastControl.octave_fold, mirror .process_ruby.
      #
      #     play seq(A2, C3, E3, G3).n8.loop.freq.within(2.hz..8.hz).tone.square.at(0.2)   # melody as clicks per second
      #     play (midi.freq.within(E1..E2)).tone.saw.lp4(600) * midi.amp_env              # any key, bass register
      class Within
        include GraphNode
        include SampleRateHelper
        node_traits memory: :none

        # The OctaveFold (the range and its rules).
        attr_reader :fold

        # Frequencies of +source+ (a node of Hz) moved into +range+ by
        # octaves (see the class description and MB::Sound::OctaveFold).
        def initialize(source, range)
          raise ArgumentError, "within takes a graph node of frequencies (got #{source.inspect})" unless source.respond_to?(:sample)

          @fold = MB::Sound::OctaveFold[range]
          @source = source.get_sampler
          @sample_rate = source.sample_rate.to_f
          @tuning = @fold.notes? ? MB::Sound.tuning : nil
          @tuning_note = nil
          @tuning_frequency = nil
          @lo, @hi = @fold.hz_bounds(@tuning || MB::Sound.tuning)
          @exclusive = @fold.exclusive?
          @out = nil
          @node_type_name = "within(#{@fold})"
        end

        def sources
          { input: @source }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil? || data.empty?

          data = Within.real_input(data)
          update_bounds if @tuning
          n = data.length
          @out = Numo::SFloat.zeros(n) if @out.nil? || @out.length != n
          Kernels.octave_fold(data, @out, @lo, @hi, @exclusive)
        end

        def to_s
          "#{super} -- within #{@fold}"
        end

        # +data+ as a contiguous SFloat (complex signals raise).
        def self.real_input(data)
          return data if data.is_a?(Numo::SFloat) && data.contiguous?
          raise ArgumentError, 'within takes real signals of frequencies (take .real or .abs first)' if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          Numo::SFloat.cast(data)
        end

        # The exact Ruby mirror of MB::Sound::FastControl.octave_fold (the
        # same arguments, the same double operations: OctaveFold.fold_hz with
        # the edges rounded to float32).
        def self.process_ruby(x, out, lo, hi, exclusive)
          n = x.length
          raise ArgumentError, 'The output must have as many values as the input' if out.length != n

          lo = Numo::SFloat[lo][0]
          hi = Numo::SFloat[hi][0]
          raise ArgumentError, 'The range must run from a low frequency above 0 to a higher one' unless lo > 0 && hi >= lo && hi.finite?

          ys = x.to_a.map { |v| MB::Sound::OctaveFold.fold_hz(v, lo, hi, exclusive) }
          out[0..] = Numo::SFloat.cast(ys) if n > 0
          out
        end

        private

        # Converts note ends to Hz when the tuning changed (allocates
        # nothing while it holds).
        def update_bounds
          return if @tuning.note == @tuning_note && @tuning.frequency == @tuning_frequency

          @tuning_note = @tuning.note
          @tuning_frequency = @tuning.frequency
          @lo, @hi = @fold.hz_bounds(@tuning)
        end
      end

      Kernels.register :octave_fold, c: FastControl.method(:octave_fold), ruby: Within.method(:process_ruby),
        about: 'frequencies moved into a range by octaves (GraphNode::Within)'
    end
  end
end
