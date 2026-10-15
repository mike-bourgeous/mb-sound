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

        # +title+: a short heading on the pane's first row (nil for none;
        # one-row panes usually have none).
        def initialize(name, rate: 10, height: 3, width: 24, needs: [], title: nil, &block)
          raise ArgumentError, "Pane names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "Pane rates are positive numbers of redraws per second (got #{rate.inspect})" unless rate.is_a?(Numeric) && rate > 0
          raise ArgumentError, "Pane heights are positive Integers (got #{height.inspect})" unless height.is_a?(Integer) && height > 0

          @name = name
          @rate = rate
          @height = height
          @width = width
          @needs = Array(needs).freeze
          @title = title
          @block = block
        end

        # Draws the pane: its title, then #draw_body (or the block given to
        # .new, called with the Canvas below the title and the Snapshot).
        # +state+ is a Hash kept for this placement of the pane.
        def draw(c, s, state)
          c.clear
          if @title
            c.text(0, 0, (@title_text ||= @title.to_s.upcase.freeze), :title)
            body = (state[:body] ||= c.sub(0, 1, c.w, c.h - 1))
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

        # True for panes that write their own terminal bytes (Plot::Live
        # panes) instead of cells (see ScopePane).
        def bytes?
          false
        end

        def inspect
          "#<UI::Pane #{@name.inspect} #{@height} row#{'s' unless @height == 1}, #{MB::M.sigfigs(@rate, 3)}/s#{@needs.empty? ? '' : " needs #{@needs.map(&:inspect).join(', ')}"}>"
        end
      end
    end
  end
end
