require 'fileutils'

require_relative 'ui/snapshot'
require_relative 'ui/poll'
require_relative 'ui/canvas'
require_relative 'ui/pane'
require_relative 'ui/panes'
require_relative 'ui/layout'
require_relative 'ui/screen'
require_relative 'ui/band'
require_relative 'ui/reline_guard'
require_relative 'ui/console'

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

        # State glyphs (:unicode or :ascii; see UI::GLYPHS).
        attr_accessor :glyphs

        # The layout `ui` shows without a name.
        attr_accessor :default_layout

        # False turns off the console prompt's status (see .prompt_status).
        attr_accessor :prompt_status_enabled
      end
      self.glyphs = ENV['MB_SOUND_UI_GLYPHS'] == 'ascii' ? :ascii : :unicode
      self.default_layout = :band
      self.prompt_status_enabled = true

      # The panes by name (built-in and defined with `pane`).
      def self.panes
        @panes ||= [
          Panes::Transport.new, Panes::Form.new, Panes::Tracks.new, Panes::Queue.new,
          Panes::Knobs.new, Panes::Meters.new, Panes::CPU.new, Panes::Scope.new,
        ].to_h { |p| [p.name, p] }
      end

      # The layouts by name (built-in and defined with `layout`; saved ones
      # load when first shown).
      def self.layouts
        @layouts ||= {
          band: Layout.new(:band) {
            cols { pane :transport; pane :form }
            cols { pane :tracks; pane :queue; pane :meters; pane :scope }
          },
          deck: Layout.new(:deck) {
            cols { pane :transport; pane :form }
            cols { pane :tracks; pane :queue; pane :knobs }
            cols { pane :meters; pane :cpu; pane :scope }
          },
          mini: Layout.new(:mini) {
            cols { pane :transport; pane :form }
          },
        }
      end

      # Options saved with layouts (e.g. at: :bottom), by name.
      def self.layout_options
        @layout_options ||= {}
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
        return name if name.is_a?(Layout)
        raise ArgumentError, "Layout names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        return layouts[name] if layouts.key?(name)

        path = File.join(layouts_dir, "#{name}.rb")
        if File.file?(path)
          layout, opts = LayoutLoader.parse(File.read(path), path)
          layouts[name] = layout
          layout_options[name] = opts
          return layout
        end

        known = (layouts.keys + saved_layouts).uniq
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
        if name.nil? && @band&.active? && opts.empty?
          return @band
        end

        layout = layout_named(name || (@band&.active? ? @band.layout.name : default_layout))
        opts = (layout_options[layout.name] || {}).merge(opts)
        if @band&.active?
          same = opts.all? { |k, v| k == :at ? @band.position == v : k == :color ? @band.mode == v : k == :look ? @band.look == v : false }
          if same
            @band.layout = layout
            return @band
          end
          @band.stop
        end

        @band = Band.new(layout: layout, io: io, **opts)
        @band.start
        unless @at_exit
          at_exit { @band&.stop rescue nil }
          @at_exit = true
        end
        @band
      end

      # Turns the band off.  Returns nil.
      def self.off
        @band&.stop
        nil
      end

      # Defines (or replaces) a pane; redraws it if it is on screen.
      def self.define_pane(name, **opts, &block)
        p = Pane.new(name, **opts, &block)
        panes[name] = p
        @band.layout = @band.layout if @band&.active? && @band.layout.pane_names.include?(name)
        p
      end

      # Defines (or replaces) a layout; shows it if the band shows a layout
      # of that name.
      def self.define_layout(name, **opts, &block)
        l = Layout.new(name, &block)
        layouts[name] = l
        layout_options[name] = opts unless opts.empty?
        @band.layout = l if @band&.active? && @band.layout.name == name
        l
      end

      # A short status for the console prompt: bar:beat, armed and
      # recording tracks, and render load, e.g. "17:3 rec:lead 31%"; nil
      # without a Session that has rendered.  With +color+, colors are wrapped in
      # \1 and \2 for Reline's prompt width.  Reads nothing that takes the
      # render lock.
      def self.prompt_status(color: true)
        return nil unless prompt_status_enabled
        s = Session.existing
        rec = s&.transport_record
        return nil if s.nil? || rec.nil? || s.frame.to_i == 0

        c = ->(code, text) { color ? "\1\e[#{code}m\2#{text}\1\e[0m\2" : text }
        stamp = Session::Stamp.at(rec[:pos], s.transport)
        out = [c.(rec[:playing] ? '33' : '2', "#{stamp.bar}:#{stamp.beat.floor}")]
        armed = s.arrangement.armed.keys
        pos = s.transport.position
        recording = s.journal.changes.select { |e| e.kind == :rec && e.status == :landed && e.data[:ends]&.pos.to_r > pos }.map(&:subject)
        out << c.('31', "rec:#{recording.join(',')}") unless recording.empty?
        out << c.('33', "arm:#{(armed - recording).join(',')}") unless (armed - recording).empty?
        load = s.render_load
        out << c.(load < 0.5 ? '2' : load < 0.8 ? '33' : '31', "#{(load * 100).round}%") if load
        out.join(' ')
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
