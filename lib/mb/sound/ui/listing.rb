module MB
  module Sound
    module UI
      # The terminal's size: `ui.size` (ux-1 r3 item 14), e.g. 40x120 (rows
      # x columns, as `stty size` prints them).
      Size = Data.define(:rows, :cols) do
        def to_s = "#{rows}x#{cols}"
        def inspect = to_s
        def to_a = [rows, cols]
      end

      # One pane on screen for `ui.list`: its NAV +number+ (nil in a band),
      # +name+, +kind+ (the pane class, or :repl, :empty), +title+, its
      # +rect+ (WxH+X+Y), +focused+, +zoomed+, +rate+ (draws per second),
      # +look+ (plot panes), and where its +title_at+ (:rule, :inside, :none).
      PaneOnScreen = Data.define(:number, :name, :kind, :title, :rect, :focused, :zoomed, :rate, :look, :title_at)

      # What the terminal UI shows now (`ui.list`, like Thread.list: ux-1
      # r3 item 27): +mode+ (:band, :tiles, :hidden, :off), +layout+ name,
      # +size+, the size +density+ decision, +panes+ (PaneOnScreen, in
      # reading order), +keys+ (the keyboard: mode, note-off mode, entry),
      # +messages+ (total and unread), +pacing+ (refreshes and written
      # frames per second).  Frozen; prints as a table.
      Listing = Data.define(:mode, :layout, :size, :density, :panes, :keys, :messages, :pacing) do
        def to_s = lines.join("\n")
        def inspect = to_s
        def pretty_print(q) = q.text(to_s)

        def lines
          head = "ui #{mode}#{layout ? " #{layout.inspect}" : ''} on #{size}#{density ? " (#{density.level}#{density.rule ? ', rule' : ''}#{density.boxes ? ', boxes' : ''}#{density.header_rule ? ', header rule' : ''})" : ''}"
          k = keys
          tail = "keyboard #{k[:active] ? 'playing' : 'idle'} (#{k[:entry]}, note-off #{k[:off]}) · messages #{messages[:total]} (#{messages[:unread]} unread)" \
                 "#{pacing ? " · #{pacing}" : ''}"
          return [head, tail] if panes.empty?

          rows = panes.map { |p|
            [p.number, p.name, p.kind, p.rect.to_s, [p.focused ? 'focus' : nil, p.zoomed ? 'zoom' : nil].compact.join(' '), p.rate, p.look, p.title_at]
          }
          [head, *Sound::Table.new(rows, header: %w[# pane kind rect state rate look title]).lines(color: false), tail]
        end
      end

      # One pane kind for `ui.panes` (ux-1 r3 item 40): +name+, +kind+ (the
      # class, or :custom for `pane :x do ... end`), +description+, +rate+,
      # +height+ (natural), +min_height+, the built-in +layouts+ that show
      # it, and +open+ (how to show it).
      PaneEntry = Data.define(:name, :kind, :description, :rate, :height, :min_height, :layouts, :open)

      # Every pane there is (`ui.panes`): built-in, defined with `pane`,
      # and from pane files.  Frozen; prints as a table; one registry feeds
      # it, help :ui, help search, and the palette's `show` completion.
      PaneCatalog = Data.define(:entries) do
        def to_s = lines.join("\n")
        def inspect = to_s
        def pretty_print(q) = q.text(to_s)
        def names = entries.map(&:name)
        def [](name) = entries.find { |e| e.name == name }

        def lines
          rows = entries.map { |e| [e.name, e.description || '', e.layouts.map(&:inspect).join(' '), e.open] }
          Sound::Table.new(rows, header: %w[pane what layouts open], title: "#{entries.length} panes (ui.list: what is on screen)").lines(color: false)
        end
      end

      # Panes that commands open, not layouts (so no built-in layout shows
      # them): name => the command.
      ON_DEMAND_PANES = { message: 'ui.message n' }.freeze

      # The set's panes, shown by `ui :session` (and buses in :studio's
      # tabs) rather than on the :wall, which shows every other pane.
      SESSION_PANES = %i[buses log lane clips midi].freeze

      class << self
        # The terminal's size (the screen's, else the console's).
        def size
          s = screen
          return Size.new(rows: s.rows, cols: s.cols) if s
          rows, cols = IO.console&.winsize
          rows.to_i > 0 && cols.to_i > 0 ? Size.new(rows: rows, cols: cols) : Size.new(rows: MB::U.height, cols: MB::U.width)
        rescue StandardError
          Size.new(rows: 24, cols: 80)
        end

        # What the UI shows now (see Listing): the screen's #list, or an
        # empty listing with the terminal's size when no screen is up.
        def list
          s = screen
          return s.list if s
          Listing.new(mode: @tiles&.hidden? ? :hidden : :off, layout: @tiles&.hidden? ? @tiles.layout_name : nil, size: size,
                      density: nil, panes: [].freeze, keys: keys_info, messages: messages_info, pacing: nil)
        end

        # Every pane kind (see PaneCatalog; +open+ is how to show one in the
        # tiles: `ui.show :name`, `:show :name` in the palette, or a layout).
        def pane_catalog
          used = Hash.new { |h, k| h[k] = [] }
          { **layouts, **tile_layouts, **show_layouts }.each do |lname, l|
            names = l.is_a?(Viewports::Layout) ? l.panes : walk_names(l)
            names.each { |n| used[n] << lname }
          end
          entries = panes.values.map do |p|
            builtin = p.class.name.to_s.start_with?('MB::Sound::UI::Panes::')
            open = ON_DEMAND_PANES[p.name] || "ui.show #{p.name.inspect}"
            PaneEntry.new(name: p.name, kind: builtin ? p.class.name.split('::').last.downcase.to_sym : :custom,
                          description: p.description, rate: p.rate, height: p.height, min_height: p.min_height,
                          layouts: used[p.name].uniq.freeze, open: open)
          end
          PaneCatalog.new(entries: entries.freeze)
        end

        # The keyboard's state for Listing.
        def keys_info
          kb = @keyboard
          return { active: false, entry: :play, off: :auto }.freeze unless kb
          { active: kb.active?, entry: kb.entry, off: kb.off_mode }.freeze
        rescue StandardError
          { active: false, entry: :play, off: :auto }.freeze
        end

        # The messages' counts for Listing.
        def messages_info
          { total: messages.total, unread: messages.unread }.freeze
        end

        private

        # Pane names of a band Layout (including `only:` panes).
        def walk_names(layout)
          walk = ->(n) { n.kind == :pane ? [n.name] : n.children.flat_map(&walk) }
          walk.(layout.root)
        end
      end

      # #size, #list, and #panes for a screen (Band, Tiles): the same
      # surface in every mode (ux-1 r3 items 14, 27, 40; the `ui` facade
      # delegates here).  Uses #rows, #cols, #density, and #listed_panes.
      module Listable
        # The terminal's size (rows x columns).
        def size = Size.new(rows: rows, cols: cols)

        # What is on screen (see UI::Listing).
        def list
          Listing.new(mode: listing_mode, layout: listing_layout, size: size, density: density, panes: listed_panes.freeze,
                      keys: UI.keys_info, messages: UI.messages_info, pacing: (@pacer.readout rescue nil))
        end

        # Every pane kind there is (see UI.pane_catalog).
        def panes = UI.pane_catalog
      end
    end
  end
end
