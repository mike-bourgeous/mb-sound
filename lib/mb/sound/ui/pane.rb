module MB
  module Sound
    module UI
      # A pane (a "module" of the UI): what it draws from a Snapshot, how
      # often (+rate+, redraws per second: meters fast, lists slow), its
      # natural size (+height+ rows including its title, +width+ a hint
      # used as its weight in a row of panes), and what it +needs+ the feed
      # to collect (:meters, :scope).  Panes draw only from the snapshot
      # (never from the Session), into a Canvas.
      #
      #     pane :bass, rate: 10, height: 2 do |c, s|
      #       part = s.players.find { |p| p.name == :bass }
      #       c.puts ['bass ', :name], [part ? part.state.to_s : 'off', :dim]
      #     end
      class Pane
        attr_reader :name, :rate, :height, :width, :needs, :title

        # One line saying what the pane shows (`ui.panes`, help :ui, help
        # search).
        attr_reader :description

        # The fewest rows the pane can show (the tiled screen's placement
        # never goes below it while the terminal has room; nil: 1).
        attr_reader :min_height

        # +title+: a short heading on the pane's first row (nil for none;
        # one-row panes usually have none).  +min_height+: see #min_height.
        def initialize(name, rate: 10, height: 3, width: 24, needs: [], title: nil, min_height: nil, description: nil, &block)
          raise ArgumentError, "Pane names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "Pane rates are positive numbers of redraws per second (got #{rate.inspect})" unless rate.is_a?(Numeric) && rate > 0
          raise ArgumentError, "Pane heights are positive Integers (got #{height.inspect})" unless height.is_a?(Integer) && height > 0

          @name = name
          @rate = rate
          @height = height
          @width = width
          @needs = Array(needs).freeze
          @title = title
          @min_height = min_height
          @description = description
          raise ArgumentError, "Pane min_height is a positive Integer (got #{min_height.inspect})" unless min_height.nil? || (min_height.is_a?(Integer) && min_height > 0)
          @block = block
        end

        # Draws the pane: its title, then #draw_body (or the block given to
        # .new, called with the Canvas below the title and the Snapshot).
        # +state+ is a Hash kept for this placement of the pane.
        def draw(c, s, state)
          c.clear
          # (A screen that sets its title into the rule above the pane sets
          # state[:title_in_rule]: the body starts on the first row)
          if @title && !state[:title_in_rule]
            c.text(0, 0, (@title_text ||= @title.to_s.upcase.freeze), :title)
            # The body follows the canvas: a relayout (resize, another
            # layout, a split) gives the pane a new canvas, and a body kept
            # from the old one would keep drawing where the pane used to be
            unless state[:body_of].equal?(c)
              state[:body] = c.sub(0, 1, c.w, c.h - 1)
              state[:body_of] = c
            end
            body = state[:body]
            body.row = 0
            c = body
          end
          if @block
            @block.arity == 3 ? @block.call(c, s, state) : @block.call(c, s)
          else
            draw_body(c, s, state)
          end
        end

        # Drawn by subclasses.
        def draw_body(c, s, state); end

        # Options #configured takes.
        CONFIG = %i[rate height width title min_height description].freeze

        # A copy named +name+ with other +rate+, +height+, +width+, or
        # +title+ (pane files and layouts configure kinds this way).
        def configured(name, **opts)
          bad = opts.keys - CONFIG
          raise ArgumentError, "Unknown pane option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')} (#{CONFIG.map(&:inspect).join(', ')})" unless bad.empty?
          raise ArgumentError, "Pane names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          copy = dup
          copy.instance_variable_set(:@name, name)
          copy.instance_variable_set(:@rate, opts[:rate]) if opts.key?(:rate)
          copy.instance_variable_set(:@height, opts[:height]) if opts.key?(:height)
          copy.instance_variable_set(:@width, opts[:width]) if opts.key?(:width)
          copy.instance_variable_set(:@min_height, opts[:min_height]) if opts.key?(:min_height)
          copy.instance_variable_set(:@description, opts[:description]) if opts.key?(:description)
          if opts.key?(:title)
            copy.instance_variable_set(:@title, opts[:title])
            copy.instance_variable_set(:@title_text, nil)
          end
          copy
        end

        # Rows the pane takes when its jump letter puts it, for a while, on
        # a screen whose layout (pane names +names+) lacks it (Tiles#jump;
        # the library picker beside the inspector on ui :sound's 80x24
        # layout), or nil: its jump letter isn't bound there.
        def temporary_rows(_names) = nil

        # True for Plot::Live panes (scope, spectrum), whose look can change
        # (`ui.look`) and whose #draw takes the screen's look as +look:+.
        # Every pane, plot panes too, draws only into its Canvas: the
        # screen's one grid, under the overlays (ui-fix-3).
        def plot?
          false
        end

        def inspect
          "#<UI::Pane #{@name.inspect} #{@height} row#{'s' unless @height == 1}, #{MB::M.sigfigs(@rate, 3)}/s#{@needs.empty? ? '' : " needs #{@needs.map(&:inspect).join(', ')}"}>"
        end
      end
    end
  end
end
