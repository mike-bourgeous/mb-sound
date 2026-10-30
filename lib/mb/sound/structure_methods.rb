module MB
  module Sound
    # Console methods for music structure analysis (see MB::Sound::Structure).
    module StructureMethods
      # Analyzes the tempo, beats, bars, meter, and sections of +source+ and
      # returns a Structure::Result (sections, letter labels, the song as a
      # flow, :analysis markers, and a comparison with the form that played
      # are computed when first asked for).
      #
      # +source+ is a sound filename, audio data (an Array of channels or a
      # Numo array at +:sample_rate+), or a graph (a GraphNode or Channels
      # bundle) rendered for +bars:+ or +seconds:+ at +bpm:+.  A block
      # renders like PlaybackMethods#render's block (bg, at_bar, meter, ...).
      #
      # Our own renders (a graph or a block) use the render's exact grid by
      # default (the tempo and meter map the render ended with); pass
      # +grid: false+ to track the beats instead (e.g. to test the tracker).
      # Files and data are tracked unless +grid:+ gives a Transport or a
      # Session whose timeline started at the start of the audio (+start:+
      # seconds otherwise).
      #
      # Other options go to Structure.analyze (+bpm:+ as a tempo hint,
      # +beats: :dp+, +beats_per_bar:+, ...).
      #
      # Examples:
      #     s = analyze_form('sounds/song.flac')
      #     s.tempo                 # => 126.002
      #     s.bars.first(3)         # Structure::Bar entries with seconds and beats
      #     s.irregular_bars        # e.g. a 2/4 gap bar
      #     puts s.meters_ruby      # meter 2, 4, at: bar(33) ...
      #     analyze_form(groove, bars: 4, bpm: 112).beats.first(4)
      #     analyze_form(bars: 8) { bg :drums, beat; meter 2, 4, at: bar(5) }
      #     s.sections              # Structure::Section entries: A, B, A', ...
      #     puts s.flow_ruby        # bpm, meters, and a flow block with comments
      #     s.markers!              # :analysis markers: seek :"analysis/b_1"
      #     s.compare(take.form)    # boundaries and labels against the flow played
      def analyze_form(source = nil, bars: nil, seconds: nil, bpm: nil, grid: :auto, sample_rate: 48000, **options, &block)
        if source.is_a?(GraphNode) || source.is_a?(GraphNode::Channels) || (source.nil? && block)
          raise ArgumentError, 'Pass bars: or seconds: to analyze a graph (it may play forever)' if bars.nil? && seconds.nil? && !block

          capture = Structure::Capture.new(sample_rate: sample_rate)
          render_transport = nil
          sounds = source ? [source] : []
          render(capture, *sounds, bars: bars, seconds: seconds, bpm: bpm) do
            render_transport = transport
            block&.call
          end

          grid = render_transport if grid == :auto
          return Structure.analyze(capture.data, sample_rate: sample_rate, bpm: grid ? nil : bpm, grid: grid || nil, **options)
        end

        raise ArgumentError, 'bars: and seconds: are for rendering graphs' if bars || seconds
        raise ArgumentError, 'A block is for rendering; pass audio or a filename, or only a block' if block

        Structure.analyze(source, sample_rate: sample_rate, bpm: bpm, grid: grid == :auto ? nil : (grid || nil), **options)
      end
      alias analyze_structure analyze_form
    end
  end
end
