module MB
  module Sound
    module UI
      # What `ui` returns (ux-1 round 3 item 8, pattern C): one object with
      # the same public surface whatever is on screen (the tiled screen,
      # the band, or nothing).  Commands go to the screen on now; a
      # command only the other kind of screen has says what to do instead
      # (and KEYS, `ui.keys`, switches to the tiles from anywhere), so no
      # `ui.x` raises NoMethodError because of the mode.
      #
      #     ui.keys          # from the band too: the tiled :keys screen
      #     ui.bind ['k', :ctrl], :keys
      #     ui.mode          # => :band
      #     ui.screen        # the Band or Tiles itself
      class Facade
        # The mode: :tiles, :band, :hidden (tiles hidden with Ctrl-Z), :off.
        def mode
          t = UI.tiles
          return :tiles if t&.active?
          return :band if UI.band&.active?
          return :hidden if t&.hidden?
          :off
        end

        # The screen on (Tiles or Band; hidden tiles too), or nil.
        def screen
          UI.screen || (UI.tiles if UI.tiles&.hidden?)
        end

        # KEYS mode (see UI::Tiles#keys): opens the tiled :keys screen from
        # the band or the plain console.
        def keys(on = true, **opts)
          t = screen
          return t.keys(on, **opts) if t.is_a?(Tiles)
          return self unless on
          UI.show(:keys).keys(**opts)
        end

        # The virtual keyboard (UI::Keyboard).
        def keyboard = UI.keyboard

        # Binds a key for the tiled screen (see UI::Keys.bind); any mode.
        def bind(key, action, *args, mode: :repl, help: nil)
          note = Keys.bind(key, action, *args, mode: mode, help: help)
          puts "\e[2mui.bind: #{note}\e[0m"
          self
        end

        # Removes a #bind binding.
        def unbind(key, mode: :repl)
          Keys.unbind(key, mode: mode)
          self
        end

        # The key table as text (every mode; see UI::Keys).
        def key_table = Tiles.key_table

        # Turns the screen off (as `ui off`).
        def off = UI.off

        def respond_to_missing?(name, include_private = false)
          Tiles.public_method_defined?(name) || Band.public_method_defined?(name) || super
        end

        def method_missing(name, *args, **opts, &block)
          s = screen
          return s.public_send(name, *args, **opts, &block) if s.respond_to?(name)
          return super unless respond_to_missing?(name)
          hint =
            case mode
            when :band then "the tiled screen's (`ui :tiles`, or Ctrl-] from the console)"
            when :tiles then "the band's (`ui :band`)"
            else 'a screen\'s: none is on (`ui` shows the band, `ui :tiles` the tiled screen)'
            end
          $stdout.puts "\e[33mui.#{name}: #{hint}\e[0m"
          nil
        end

        def inspect
          s = screen
          s ? s.inspect : '#<UI off (ui: the band, ui :tiles: the tiled screen)>'
        end

        def pretty_print(q) = q.text(inspect)
      end

      # True if the current thread runs the REPL's commands (warnings it
      # raises print in the REPL; see Tiles#repl_thread?).
      def self.repl_thread?
        s = screen
        s.respond_to?(:repl_thread?) && s.repl_thread?
      end

      # The `ui` facade (one per process).
      def self.facade
        @facade ||= Facade.new
      end
    end
  end
end
