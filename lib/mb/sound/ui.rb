require 'fileutils'

require_relative 'ui/snapshot'
require_relative 'ui/poll'
require_relative 'ui/data_file'
require_relative 'ui/themes/theme_set'
require_relative 'ui/canvas'
require_relative 'ui/density'
require_relative 'ui/pane'
require_relative 'ui/panes'
require_relative 'ui/pane_files'
require_relative 'ui/layout'
require_relative 'ui/screen'
require_relative 'ui/follow'
require_relative 'ui/frame_rate'
require_relative 'ui/band'
require_relative 'ui/reline_guard'
require_relative 'ui/console'
require_relative 'ui/prompt'
require_relative 'ui/messages'
require_relative 'ui/warm_up'
require_relative 'ui/screen/vt'
require_relative 'ui/input/events'
require_relative 'ui/input/decoder'
require_relative 'ui/input/router'
require_relative 'ui/input/repl_host'
require_relative 'ui/viewports/tree'
require_relative 'ui/viewports/tiler'
require_relative 'ui/viewports/loader'
require_relative 'ui/chrome'
require_relative 'ui/screen/term'
require_relative 'ui/keyboard'
require_relative 'ui/tiles'

module MB
  module Sound
    # The live terminal UI (design/notes/terminal_ui.md), step 1: a
    # read-only dashboard band above (or below) the console, with Pry
    # unchanged in the scroll region below it.
    #
    # The Session's render thread publishes a frozen Snapshot per buffer
    # (UI::Feed; only while the painter keeps up) and a painter thread draws
    # the panes from snapshots ("snapshots in, cells out"), each at its own
    # rate, into a native cell grid (FastUI::Grid), passing the GVL between
    # panes, and writes only the cells that changed.
    #
    #     ui                    # the default band (transport, form, tracks, queued, meters, scope)
    #     ui :deck              # the taller band with knobs and CPU
    #     ui off                # (or ui :off, ui false)
    #     pane :hi, height: 1 do |c, s| c.puts ['bar ', :dim], [s.stamp, :key] end
    #     layout :mine do cols { pane :transport; pane :hi } end
    #     ui :mine
    #     ui.save               # saves the layout as Ruby (ui :mine loads it next time)
    module UI
      class << self
        # The band on screen (or last shown), or nil.
        attr_reader :band

        # The tiled screen on screen (or last shown), or nil.
        attr_reader :tiles

        # The binding the console evaluates in (set before each line by
        # the hook from .install_pry!): the palette evaluates there.
        attr_accessor :console_binding

        # State glyphs (:unicode or :ascii; see UI::GLYPHS).
        attr_accessor :glyphs

        # The layout `ui` shows without a name.
        attr_accessor :default_layout

        # False turns off the console prompt's status (see .prompt_status).
        attr_accessor :prompt_status_enabled
      end
      self.glyphs = ENV['MB_SOUND_UI_GLYPHS'] == 'ascii' ? :ascii : :unicode
      Themes.dir = -> { File.join(UI.layouts_dir, 'themes') }
      self.default_layout = :band
      self.prompt_status_enabled = true
      install_messages! # (only acts while a screen is up; see UI::Messages)

      # The panes by name (built-in and defined with `pane`).
      def self.panes
        @panes ||= [
          Panes::Transport.new, Panes::Form.new, Panes::Tracks.new, Panes::Queue.new,
          Panes::Knobs.new, Panes::Meters.new, Panes::CPU.new, Panes::Scope.new, Panes::Spectrum.new, Panes::Messages.new, Panes::Keyboard.new,
        ].to_h { |p| [p.name, p] }
      end

      # The virtual keyboard (one per process; see UI::Keyboard and the
      # `keyboard` pane): its notes go to the current Session's MIDI input
      # through a Keyboard::Link.
      def self.keyboard
        @keyboard ||= Keyboard.new(out: Keyboard::Link.new)
      end

      # The layouts by name (built-in and defined with `layout`; saved ones
      # load when first shown).
      def self.layouts
        @layouts ||= {
          band: Layout.new(:band) {
            cols { pane :transport; pane :form }
            cols { pane :tracks; pane :queue; pane :meters; pane :scope; pane :spectrum, only: :big }
          },
          # (On a big terminal, UI::Density boxes it, grows it to a third of
          # the rows, and adds the `only: :big` panes)
          deck: Layout.new(:deck) {
            cols { pane :transport; pane :form }
            cols { pane :tracks; pane :queue; pane :knobs; pane :messages, only: :big }
            cols { pane :meters; pane :cpu; pane :scope; pane :spectrum, only: :big }
          },
          mini: Layout.new(:mini) {
            cols { pane :transport; pane :form }
          },
        }
      end

      # What each built-in layout is for, and the terminal size it wants
      # (help :ui lists them).
      LAYOUT_NOTES = {
        band: ['the default band: transport, form, tracks, queue, meters, scope', '7 rows'],
        deck: ['a taller band with knobs and CPU per part (bigger, boxed, with spectrum and messages from 160x50)', '13 rows'],
        mini: ['one line: transport and form', '1 row'],
        tiles: ['the whole screen: the console beside tracks, queue, meters, scope', '80x24 and up'],
        studio: ['tracks | the console over a scope | tabs of meters, knobs, cpu', '120x40 and up'],
        keys: ['the console over the keyboard, starting in KEYS mode', '100x30 and up'],
        wall: ['every pane at once, for big terminals', '200x60 and up'],
        show: ['song_script --ui: a big scope and spectrum, no console', '120x40 and up'],
        play: ['synth_script --ui: the keyboard, scope, spectrum, no console', '120x40 and up'],
      }.freeze

      # Every layout `ui` can show, as [name, kind (:band, :tiles, :script),
      # description, size hint, pane names, current?] rows: built-in,
      # defined with `layout`, and saved in .layouts_dir.
      def self.layout_table
        current = screen && (screen.is_a?(Tiles) ? screen.layout_name : screen.layout.name)
        names = (layouts.keys + tile_layouts.keys + show_layouts.keys + saved_layouts).uniq
        names.filter_map do |name|
          l = show_layouts[name] || (layout_named(name) rescue nil) or next
          kind = show_layouts.key?(name) ? :script : l.is_a?(Viewports::Layout) ? :tiles : :band
          panes = l.is_a?(Viewports::Layout) ? l.panes : l.pane_names
          desc, size = LAYOUT_NOTES[name] || [saved_layouts.include?(name) ? "saved in #{layouts_dir}" : 'defined with layout', nil]
          [name, kind, desc, size, panes, name == current]
        end
      end

      # Options saved with layouts (e.g. at: :bottom), by name.
      def self.layout_options
        @layout_options ||= {}
      end

      # The tiled layouts by name (those with a `repl` pane; built-in,
      # defined with `layout`, or saved).
      def self.tile_layouts
        @tile_layouts ||= {
          tiles: Viewports.layout(:tiles, focus: :repl) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              repl
              rows(width: 46) { pane :tracks; pane :queue, height: 5; pane :meters, height: 6; pane :scope, height: 8 }
            }
          },
          keys: Viewports.layout(:keys, focus: :keyboard) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              rows { repl; pane :keyboard, height: 8 }
              rows(width: 46) { pane :tracks; pane :queue, height: 5; pane :meters, height: 6 }
            }
          },
          # For big terminals (about 200x60 and up): every pane at once
          wall: Viewports.layout(:wall, focus: :repl) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              rows(width: 40) { pane :tracks; pane :queue, height: 8; pane :knobs, height: 10; pane :cpu, height: 10 }
              rows(weight: 3) { repl; pane :keyboard, height: 8 }
              rows(width: 60) { pane :meters, height: 6; pane :scope, height: 14; pane :spectrum, height: 14; pane :messages }
            }
          },
          studio: Viewports.layout(:studio, focus: :repl) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              rows(width: 32) { pane :tracks; pane :queue, height: 6 }
              rows(weight: 3) { repl; pane :scope, height: 8 }
              tabs :meters, :knobs, :cpu, width: 34
            }
          },
        }
      end

      # Tiled layouts without a console, for scripts' screens (song_script
      # --ui, synth_script --ui; see ScriptRunner and Tiles' repl: :none).
      def self.show_layouts
        @show_layouts ||= {
          # A song: where it is, the tracks, a big scope and spectrum, meters, knobs
          show: Viewports.layout(:show) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              rows(width: 36) { pane :tracks; pane :queue, height: 6; pane :knobs, height: 8 }
              rows(weight: 3) { pane :scope; pane :spectrum, height: 12 }
              rows(width: 34) { pane :meters, height: 7; pane :cpu; pane :messages, height: 6 }
            }
          },
          # A synth or effect: the keyboard, scope, spectrum, meters
          play: Viewports.layout(:play, focus: :keyboard) {
            cols(height: 1) { pane :transport; pane :form }
            cols {
              rows(weight: 3) { pane :scope; pane :spectrum, height: 10; pane :keyboard, height: 10 }
              rows(width: 34) { pane :meters, height: 7; pane :knobs; pane :cpu, height: 7; pane :messages, height: 6 }
            }
          },
        }
      end

      # The tiled layout named +name+ (a Viewports::Layout with a repl
      # pane): defined, built in, or saved.  Raises with suggestions.
      def self.tiles_layout_named(name)
        return name if name.is_a?(Viewports::Layout)
        l = layout_named(name)
        raise ArgumentError, "Layout #{name.inspect} has no repl pane, so it shows as a band (`ui #{name.inspect}`); a tiled layout needs `repl`" unless l.is_a?(Viewports::Layout)
        l
      end

      # Writes layout text +text+ as +name+ in .layouts_dir.  Returns the
      # path.
      def self.save_layout_text(name, text)
        raise ArgumentError, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        dir = layouts_dir
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{name}.rb")
        File.write(path, "# mb-sound terminal UI layout: `ui #{name.inspect}` shows it (see help :ui)\n#{text}")
        @layout_mtimes&.delete(path)
        path
      end

      # Runs console +code+ for a UI action (KEYS mode's Enter capture,
      # step entry's swap) in +session+'s context, as a line of the
      # console's take when that take records +session+, so a replay of
      # the take repeats it where it landed.  Returns the result.
      def self.run_line(code, session)
        take = Take.active
        b = Take.console_binding
        Session.with_context(session: session) do
          take&.session_ok?(session) ? take.line(code, b) : b.eval(code, '(ui)', 1)
        end
      end

      # Where +error+ came from in the user's code (see
      # Internal.error_origin).
      def self.error_origin(error) = Internal.error_origin(error)

      # Records the console's binding before each line (for the palette).
      # Called by bin/sound.rb.
      def self.install_pry!
        return unless defined?(::Pry)
        ::Pry.config.hooks.add_hook(:before_eval, :mb_sound_ui) { |_code, pry| UI.console_binding = pry.current_binding }
      end

      # Where Band#save writes layouts: $MB_SOUND_UI_DIR, else the user data
      # directory's mb-sound/ui.
      def self.layouts_dir
        env = ENV['MB_SOUND_UI_DIR']
        return File.expand_path(env) unless env.to_s.empty?
        if RbConfig::CONFIG['host_os'] =~ /darwin/
          File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'ui')
        else
          base = ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME']
          File.join(base, 'mb-sound', 'ui')
        end
      end

      # The layout named +name+: defined, built in, or saved in
      # .layouts_dir (loaded with LayoutLoader).  Raises with suggestions.
      def self.layout_named(name)
        return name if name.is_a?(Layout) || name.is_a?(Viewports::Layout)
        raise ArgumentError, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)

        path = File.join(layouts_dir, "#{name}.rb")
        reload = File.file?(path) && (@layout_mtimes ||= {})[path] != File.mtime(path)
        return tile_layouts[name] if tile_layouts.key?(name) && !reload
        return layouts[name] if layouts.key?(name) && !reload

        if File.file?(path)
          text = File.read(path)
          tiled, opts = Viewports::Loader.parse(text, path, extra: %i[at color look]) rescue nil
          @layout_mtimes[path] = File.mtime(path)
          if tiled&.repl?
            layouts.delete(name)
            tile_layouts[name] = tiled
            layout_options[name] = opts
            return tiled
          end
          layout, opts = LayoutLoader.parse(text, path)
          tile_layouts.delete(name)
          layouts[name] = layout
          layout_options[name] = opts
          return layout
        end

        known = (layouts.keys + tile_layouts.keys + saved_layouts).uniq
        hint = DidYouMean::SpellChecker.new(dictionary: known.map(&:to_s)).correct(name.to_s).first
        raise ArgumentError, "No layout #{name.inspect}#{hint ? " (did you mean :#{hint}?)" : ''} (layouts: #{known.map(&:inspect).join(', ')})"
      end

      # Names of layouts saved in .layouts_dir.
      def self.saved_layouts
        Dir.glob(File.join(layouts_dir, '*.rb')).map { |f| File.basename(f, '.rb').to_sym }.sort
      end

      # Shows the band with layout +name+ (the default layout if nil),
      # replacing the layout of a band already on screen.  Options as for
      # Band.new.  Returns the Band.
      def self.show(name = nil, io: $stdout, **opts)
        opts = opts.compact
        if name.nil? && opts.empty?
          return @tiles if @tiles&.active?
          return @band if @band&.active?
          return show_tiles(@tiles.layout) if @tiles&.hidden? # back from Ctrl-Z
        end

        layout = layout_named(name || (@tiles&.active? ? @tiles.layout_name : @band&.active? ? @band.layout.name : default_layout))
        return show_tiles(layout, **opts) if layout.is_a?(Viewports::Layout)
        @tiles&.stop
        opts = opts.except(:mouse, :nav_esc)
        opts = (layout_options[layout.name] || {}).merge(opts)
        if @band&.active?
          same = opts.all? { |k, v| k == :at ? @band.position == v : k == :color ? @band.mode == v : k == :look ? @band.look == v : false }
          if same
            @band.layout = layout
            return @band
          end
          @band.stop
        end

        warm_up # once, before the first band (YJIT compiles the painter)
        @band = Band.new(layout: layout, io: io, **opts)
        @band.start
        unless @at_exit
          at_exit { @band&.stop rescue nil }
          @at_exit = true
        end
        @band
      end

      # Shows the tiled screen with Viewports::Layout +layout+ (or switches
      # the one on screen to it).  Options as for Tiles.new.
      def self.show_tiles(layout, at: nil, **opts)
        if @tiles&.hidden?
          # Hidden with Ctrl-Z: the same layout comes back as it was left
          if opts.empty? && (layout.equal?(@tiles.layout) || layout.name == @tiles.layout_name)
            @band&.stop
            return @tiles.start
          end
          @tiles.stop
        end
        if @tiles&.active?
          @tiles.layout(layout) if opts.empty?
          return @tiles if opts.empty?
          @tiles.stop
        end
        @band&.stop
        warm_up
        @tiles = Tiles.new(layout: layout, **opts)
        @tiles.start
        unless @at_exit_tiles
          at_exit { @tiles&.stop rescue nil }
          @at_exit_tiles = true
        end
        @tiles
      end

      # Turns the band or the tiled screen off.  Returns nil.
      def self.off
        was = screen || @tiles&.hidden?
        @band&.stop
        @tiles&.stop
        # What was hidden from the terminal while the screen owned it
        if was && (text = messages.summary)
          $stdout.puts "\e[33m#{text}\e[0m"
          messages.clear
        end
        nil
      end

      # The screen on (the tiled screen or the band), or nil.
      def self.screen
        return @tiles if @tiles&.active?
        @band if @band&.active?
      end

      # Defines (or replaces) a pane kind: the block makes a Pane from a
      # name and options (`pane :x, kind: :mine, ...` in pane files).
      #
      #     UI.pane_kind(:big_clock) { |name, **o| UI::Pane.new(name, height: 1, **o) { |c, s| c.puts [s&.stamp.to_s, :key] } }
      def self.pane_kind(kind, &block)
        raise ArgumentError, "Pane kinds are Symbols (got #{kind.inspect})" unless kind.is_a?(Symbol)
        raise ArgumentError, 'pane_kind needs a block making a Pane' unless block
        PaneFiles.kinds[kind] = block
      end

      # Defines (or replaces) pane +p+ (a Pane) by its name; redraws it if
      # it is on screen.
      def self.define_pane_object(p)
        panes[p.name] = p
        @band.layout = @band.layout if @band&.active? && @band.layout.pane_names.include?(p.name)
        @tiles&.invalidate
        p
      end

      # Reloads data files that changed (pane files, the current theme,
      # saved layouts): called by the screens' painters about once a second.
      # Returns {panes:, theme:, layouts:, errors:}.
      def self.reload_files
        errors = []
        panes_defined = PaneFiles.reload(errors)
        theme = begin
          Themes.reload_changed
        rescue DataFile::LoadError, ArgumentError => e
          errors << e.message
          false
        end
        layouts = []
        (@layout_mtimes || {}).each do |path, m|
          next unless File.file?(path) && File.mtime(path) != m
          name = File.basename(path, '.rb').to_sym
          begin
            layout_named(name)
            layouts << name
          rescue DataFile::LoadError, LayoutLoader::LoadError, ArgumentError => e
            @layout_mtimes[path] = File.mtime(path)
            errors << e.message
          end
        end
        { panes: panes_defined, theme: theme, layouts: layouts, errors: errors }
      end

      # Defines (or replaces) a pane; redraws it if it is on screen.
      def self.define_pane(name, **opts, &block)
        p = Pane.new(name, **opts, &block)
        panes[name] = p
        @tiles&.invalidate
        @band.layout = @band.layout if @band&.active? && @band.layout.pane_names.include?(name)
        p
      end

      # Defines (or replaces) a layout; shows it if the band shows a layout
      # of that name.
      def self.define_layout(name, **opts, &block)
        tiled = begin
          Viewports.layout(name, **opts.slice(:focus, :zoom, :gap), &block)
        rescue Viewports::Error, NoMethodError, ArgumentError
          nil
        end
        if tiled&.repl?
          layouts.delete(name)
          tile_layouts[name] = tiled
          @tiles.layout(tiled) if @tiles&.active? && @tiles.layout_name == name
          return tiled
        end
        opts = opts.except(:focus, :zoom, :gap)
        l = Layout.new(name, &block)
        tile_layouts.delete(name)
        layouts[name] = l
        layout_options[name] = opts unless opts.empty?
        @band.layout = l if @band&.active? && @band.layout.name == name
        l
      end

      # A short status for the console prompt: what only commands change
      # (the prompt is drawn once per line, so a playback position or load
      # would be stale at once; the band, the tiles' status line, and `now`
      # show those): recording and armed tracks and the form's section (or
      # the scene), e.g. "●rec:lead arm:pad drop"; nil when there is none.
      # With +color+, colors are wrapped in \1 and \2 for Reline's prompt
      # width.  Reads nothing that takes the render lock.
      def self.prompt_status(color: true)
        return nil unless prompt_status_enabled
        s = Session.existing
        return nil if s.nil?

        c = ->(code, text) { color ? "\1\e[#{code}m\2#{text}\1\e[0m\2" : text }
        out = []
        armed = s.arrangement.armed.keys
        pos = s.transport.position
        recording = s.journal.changes.select { |e| e.kind == :rec && e.status == :landed && e.data[:ends]&.pos.to_r > pos }.map(&:subject)
        out << c.('31', "#{glyphs == :ascii ? '*' : '●'}rec:#{recording.join(',')}") unless recording.empty?
        out << c.('33', "arm:#{(armed - recording).join(',')}") unless (armed - recording).empty?
        pb = s.arrangement.playback
        where = pb && !pb.ended? && pb.section ? pb.section : s.arrangement.current_scene
        out << c.('36', where.to_s) if where
        out.empty? ? nil : out.join(' ')
      rescue StandardError
        nil
      end

      # p50, p99, and max of +values+ (rounded to 3 significant figures).
      def self.percentiles(values)
        return { p50: nil, p99: nil, max: nil } if values.empty?
        v = values.sort
        pick = ->(q) { MB::M.sigfigs(v[((v.length - 1) * q).round].to_f, 3) }
        { p50: pick.(0.5), p99: pick.(0.99), max: MB::M.sigfigs(v[-1].to_f, 3) }
      end
    end
  end
end
