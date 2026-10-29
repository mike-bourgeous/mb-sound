require_relative 'cells'

module MB
  module Term
    # Which cell grid class to make: Cells (pure Ruby), or a native grid
    # with the same interface and output: NativeCells (C, when fast_term is
    # compiled), or one an adapter registers (mb-sound registers its
    # MB::Sound::Plot::Text::NativeCells, a NativeCells subclass):
    #
    #     MB::Term::Grid.native = MyNativeGrid
    #     g = MB::Term::Grid.new(80, 24)              # native when registered
    #     g = MB::Term::Grid.new(80, 24, native: false)  # always Cells
    #
    # MB_TERM_NATIVE=0 in the environment makes Grid.new give Cells.
    module Grid
      # The methods a grid class has (Cells' interface).
      INTERFACE = %i[width height set put text put_run char copy_from blit lines to_text frame].freeze

      @native = nil

      class << self
        # The registered native grid class, or nil.
        attr_reader :native

        # Registers +klass+ (nil to clear) as the native grid class; it must
        # have every method in INTERFACE.
        def native=(klass)
          if klass
            missing = INTERFACE.reject { |m| klass.method_defined?(m) }
            raise ArgumentError, "#{klass} lacks grid methods: #{missing.join(', ')}" unless missing.empty?
          end
          @native = klass
        end

        # True when a native grid is registered and not turned off by
        # MB_TERM_NATIVE=0.
        def native?
          !@native.nil? && ENV['MB_TERM_NATIVE'] != '0'
        end

        # The grid class for +native+.
        def class_for(native = native?)
          native && @native ? @native : Cells
        end

        # A new +width+ x +height+ grid (native when +native+ and one is
        # registered, else Cells).
        def new(width, height, native: native?)
          class_for(native).new(width, height)
        end
      end
    end
  end
end
