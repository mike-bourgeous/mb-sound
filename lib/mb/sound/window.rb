module MB
  module Sound
    # A base class for describing a normalized window function and its optimal
    # overlap.  All window functions should be normalized so a bin-centered 0dBFS
    # sine wave has a value of 1.0 in the FFT.
    #
    # Subclass constructors should support being called with a single argument,
    # length.
    class Window
      class << self
        # Returns all window classes that inherit from this class.
        def windows
          @@windows ||= []
          @@windows
        end

        def [](name)
          @@windows_by_name ||= {}
          @@windows_by_name[name.to_s]
        end

        private

        def inherited(subclass)
          puts "Registering window #{subclass.name} as '#{subclass.window_name}'" if $debug
          @@windows ||= []
          @@windows << subclass
          @@windows_by_name ||= {}
          @@windows_by_name[subclass.window_name] = subclass
        end
      end

      # The length of the window, in samples.
      attr_reader :length

      # The optimum overlap for flat gain, in samples.
      attr_reader :overlap

      # The hop length, for convenience, in samples (length - overlap).
      attr_reader :hop

      # The analysis window function (a Numo::NArray).  No pre-window if nil.
      attr_reader :pre_window

      # The synthesis window function (a Numo::NArray).  No post-window if nil.
      attr_reader :post_window

      # TODO: it'd be nice to have an attribute for the main lobe width.  Useful
      # for setting the peak finding window, for example.

      # Subclasses should call this to generate the window.  Subclass
      # constructors should pass length and overlap (in samples).
      def initialize(length, overlap)
        @length = length
        @overlap = overlap
        @hop = length - overlap
        @pre_window = gen_pre_window(length)
        @post_window = gen_post_window(length)

        normalize_sum(@pre_window) if @pre_window
        normalize_sum(@post_window) if @post_window
      end

      # Generates an NArray with this window overlapped +n+ times (mostly for
      # plotting and verifying overlap).
      def gen_overlap(n)
        w = MB::M.zpad(composite_window, @length + @hop * (n + 2))
        n.times.map { |t| MB::M.rol(w, -(t + 1) * @hop) }.reduce(&:+)
      end

      # Generates an NArray with this window squared and then overlapped +n+
      # times for checking power flatness.
      #
      # FIXME: is this the correct way of checking power flatness?
      def gen_power_overlap(n)
        w = MB::M.zpad(composite_window, @length + @hop * (n + 2))
        n.times.map { |t| MB::M.rol(w ** 2, (-t + 1) * @hop) }.reduce(&:+)
      end

      # Returns the pre window multiplied by the post window if both are present,
      # otherwise returns whichever window is present.
      def composite_window
        w = @pre_window || @post_window
        w *= @post_window if @pre_window && @post_window
        w
      end

      # Calculates the gain to compensate for overlapped addition based on length
      # and overlap.
      def overlap_gain
        # FIXME: this is likely wrong for other window types and overlap lengths
        @hop.to_f / @length
      end

      # Overrides the default hop size (e.g. for experimenting with different hop
      # times).
      def force_hop(hop)
        @hop = hop
        @overlap = @length - @hop
      end

      # Returns the simple class name of the window function.
      def self.window_name
        name.rpartition('::').last
      end

      # Removes lowercase letters to generate a shorter window name.
      def self.short_name
        self.window_name.gsub(/[[:lower:]]/, '')
      end

      private

      # Subclasses should override to generate a Numo::NArray for the pre-FFT
      # window.
      def gen_pre_window(length)
        nil
      end

      # Subclasses should override to generate a Numo::NArray for the post-FFT
      # window, if they want to provide one.
      def gen_post_window(length)
        nil
      end

      # Normalize window data to sum to +length+
      def normalize_sum(window)
        sum = window.sum
        window.inplace! * length / sum
        window.not_inplace!
      end
    end
  end
end

require_relative 'window/rectangular'
require_relative 'window/triangular'
require_relative 'window/hann'
require_relative 'window/hann_post'
require_relative 'window/double_hann'
require_relative 'window/pad_hann'
require_relative 'window/pad_double_hann'
require_relative 'window/bartlett_hann'
require_relative 'window/sft3f'
require_relative 'window/sft4f'
require_relative 'window/hft116d'
require_relative 'window/planck'
