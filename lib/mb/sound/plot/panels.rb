require_relative 'envelope_view'

module MB
  module Sound
    module Plot
      # Pictures of nodes at rest, drawn from frozen parameter snapshots
      # (GraphNode::Traversable#param_snapshot), never from the nodes
      # themselves: a painter thread can take a snapshot on its poll thread
      # and draw it any time (the UI contract, racks R1).  Panels draw
      # through the chart layer (ChartBuilder marks and scales), so every
      # renderer (text cells, SVG, PNG) draws them; nothing here formats
      # ANSI.
      #
      # Register a preview for a node class (by class name, so load order
      # doesn't matter; subclasses inherit it):
      #
      #     Plot::Panels.register('MB::Sound::GraphNode::Shaper') { |params, chart| ... }
      #
      # The block gets the Params snapshot and a ChartBuilder, and returns
      # a truthy value if it drew.
      module Panels
        @previews = {}

        class << self
          # Registers a preview for the class named +class_name+.
          def register(class_name, &block)
            raise ArgumentError, 'Pass a block |params, chart|' unless block
            @previews[class_name.to_s] = block
          end

          # Draws the preview for +klass+ (a node class) from +params+ (a
          # GraphNode::Traversable::Params) onto +chart+ (a ChartBuilder).
          # Returns the chart, or nil if the class has no preview or its
          # snapshot can't be drawn.  A pure function of +params+.
          #
          # +live+ is what a painter knows of the node beyond its settings
          # (nil, or a frozen Hash: an envelope's playhead and note peak,
          # see EnvelopeView.draw), passed to blocks taking a third
          # argument |params, chart, live|.
          def preview(klass, params, chart, live: nil)
            klass.ancestors.each do |a|
              blk = a.name && @previews[a.name]
              next unless blk
              return (blk.arity == 3 || blk.arity < -3 ? blk.call(params, chart, live) : blk.call(params, chart)) ? chart : nil
            end
            nil
          end

          # The class names with previews.
          def registered
            @previews.keys
          end
        end

        # Filters: the magnitude response in dB over a log frequency axis.
        register('MB::Sound::Filter::SampleWrapper') do |params, chart|
          d = params.preview
          next nil unless d

          filter =
            case d[:structure]
            when :svf then Filter::SVF.new(d[:filter_type], d[:sample_rate], d[:cutoff], quality: d[:quality], gain: d[:gain])
            when :cookbook then Filter::Cookbook.new(d[:filter_type], d[:sample_rate], d[:cutoff], quality: d[:quality], db_gain: d[:db_gain])
            end
          next nil unless filter

          f, db = Presets.response_db(filter, d[:sample_rate])
          top = [(db.max / 6.0).ceil * 6, 6].max
          chart.x :frequency, f[0]..f[-1]
          chart.y Scale::DB.new([top - 66, -60].max..top)
          chart.line db, x: f, label: d[:label]
        end

        # Four-pole filters and diode ladders (lp4, diode; sound-design-nav-1):
        # the linear response (Filter::FourPole#response, no drive) of a
        # fresh filter with the snapshot's mode, cutoff, resonance, tuning,
        # and curve; a cutoff another node moves is drawn where it was last
        # read (the label marks it with ~), with dashed rules an octave
        # either side.
        register('MB::Sound::GraphNode::FourPole') do |params, chart|
          d = params.preview
          next nil unless d.is_a?(Hash) && d[:kind] == :four_pole

          rate = d[:sample_rate]
          filter = ->(cut) {
            Filter::FourPole.new(
              cutoff: cut, resonance: d[:resonance].clamp(0.0, 1.0), mode: d[:mode], self_oscillate: d[:self_oscillate], compensation: d[:compensation],
              resonance_curve: d[:resonance_curve], normalize: d[:normalize], tuning: d[:tuning], sample_rate: rate,
              drive_mode: d[:drive_mode] == :stages && d[:mode] == :diode ? :input : d[:drive_mode], clip: d[:drive_mode] == :feedback ? d[:clip] : :soft
            )
          }
          f, db = Presets.response_db(filter.(d[:cutoff]), rate)
          top = [(db.max / 6.0).ceil * 6, 6].max
          chart.x :frequency, f[0]..f[-1]
          chart.y Scale::DB.new([top - 66, -60].max..top)
          if d[:moving]&.include?(:cutoff)
            [0.5, 2.0].each do |r|
              c = (d[:cutoff] * r).clamp(20.0, rate * 0.45)
              f2, db2 = Presets.response_db(filter.(c), rate)
              chart.line db2, x: f2, label: r < 1 ? '-1 oct' : '+1 oct'
            end
          end
          chart.line db, x: f, label: d[:label]
          chart.title d[:label]
        end

        # "2400 Hz", "12.5 kHz" for a cutoff in Hz.
        def self.hz_text(hz)
          hz >= 10_000 ? "#{format('%.3g', hz / 1000.0)} kHz" : "#{hz >= 100 ? hz.round : format('%.3g', hz)} Hz"
        end

        # Envelopes: one note through a copy rendered at a low rate, the
        # sustain held for a fixed share of the plot (EnvelopeView).
        register('MB::Sound::Envelope') do |params, chart, live|
          d = params.preview
          next nil unless d.is_a?(Hash) && d[:kind] == :envelope
          EnvelopeView.draw(d, chart, live)
        end

        # Shapers: the transfer curve over inputs -2..2, with the input as a
        # reference line.
        register('MB::Sound::GraphNode::Shaper') do |params, chart|
          d = params.preview
          cp = MB::Sound::Shaper.params(d[:mode], d[:p1], d[:p2])
          x = Numo::DFloat.linspace(-2, 2, 201)
          y = Numo::DFloat.cast(x.to_a.map { |v| MB::Sound::Shaper.f(cp, v) })
          chart.x :linear, -2..2
          chart.y :linear, -2..2
          chart.line x, x: x, label: 'input'
          chart.line y, x: x, label: d[:label]
        end
      end
    end
  end
end
