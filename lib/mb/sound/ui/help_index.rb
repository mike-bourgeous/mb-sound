module MB
  module Sound
    module UI
      # What the terminal UI adds to `help` (ux-1 r3 item 35: `help scope`
      # didn't find the scope pane): every pane kind (UI.pane_catalog),
      # layout (UI.layout_table), plot look, NAV/KEYS/STEP key
      # (Tiles::KEY_HELP), and `ui.*` method, generated from the same
      # registries the screens use, so a new pane, layout, key, or method
      # is found without touching help.  Help's search page, topic pages,
      # and method pages show the matches; a guard spec checks every pane,
      # layout, and ui method is reachable by `help <its name>`.
      module HelpIndex
        # One thing to find: +kind+ (:pane, :layout, :look, :key,
        # :ui_method), +name+ (text), +what+ it is, +how+ to get it.
        Entry = Data.define(:kind, :name, :what, :how) do
          def label = kind == :ui_method ? "ui.#{name}" : kind == :key ? "#{how} #{name}" : "#{kind} #{name}"
        end

        # Screen methods hidden from help (internals that are public for
        # the other screen classes or specs).
        HIDDEN = %i[refresh pump relayout_now invalidate inspect thread pty_thread host router term tiler feed mode rows cols
                    layout_name placed failures active? owns_terminal? hidden? listed_panes listing_mode listing_layout
                    resized! to_text key_help? mode_problems density chrome shown_layout height position band_top region
                    stats frame_rate pacer target_fps fps start stop hide act grab_key line_done mode_changed repl_key repl_paste
                    note top? plot_pane say].freeze

        module_function

        # Every entry, built now (panes and layouts can be defined at any
        # time).
        def entries
          out = []
          UI.pane_catalog.entries.each { |e| out << Entry.new(kind: :pane, name: e.name.to_s, what: e.description.to_s, how: e.open) }
          UI.layout_table.each do |name, kind, desc, size, _panes, _cur|
            out << Entry.new(kind: :layout, name: name.to_s, what: [desc, size && "(#{size})", kind == :script ? 'a script screen' : nil].compact.join(' '),
                             how: kind == :script ? "--ui #{name}" : "ui #{name.inspect}")
          end
          Plot::Text::LOOKS.each_key do |l|
            out << Entry.new(kind: :look, name: l.to_s, what: "a plot look for scope and spectrum panes#{l == :scope ? ' (Braille, the default for short or wide panes)' : ''}",
                             how: "ui.look #{l.inspect}")
          end
          Tiles::KEY_HELP.each do |mode, groups|
            groups.each do |_group, keys|
              keys.each { |k, what| out << Entry.new(kind: :key, name: k, what: what, how: mode.to_s.upcase) }
            end
          end
          ui_methods.each { |m, what| out << Entry.new(kind: :ui_method, name: m.to_s, what: what, how: "ui.#{m}") }
          out
        end

        # The `ui.*` methods people call ([name, first doc sentence]):
        # the tiled screen's and the band's public methods but internals.
        def ui_methods
          @ui_methods ||= begin
            names = (Tiles.public_instance_methods - Object.public_instance_methods) | (Band.public_instance_methods - Object.public_instance_methods)
            names = names.reject { |m| HIDDEN.include?(m) || m.to_s.end_with?('=') }
            names.sort.map { |m|
              owner = Tiles.method_defined?(m) ? Tiles : Band
              [m, summary(owner.instance_method(m))]
            }.freeze
          end
        end

        # Entries whose name or description matches +pattern+.
        def search(pattern)
          entries.select { |e| e.name.match?(pattern) || e.what.match?(pattern) }
        end

        # Entries named exactly +name+ (a String or Symbol; `ui.split` and
        # `split` both find the method).
        def named(name)
          n = name.to_s.delete_prefix('ui.').delete_prefix(':')
          entries.select { |e| e.name == n }
        end

        # Every name in the index (for did_you_mean suggestions).
        def names = entries.map(&:name).uniq

        # The first sentence of a method's doc comment (read from its source
        # file), or ''.
        def summary(method)
          file, line = method.source_location
          return '' unless file && File.file?(file)
          lines = File.readlines(file, chomp: true)
          i = line - 2
          comment = []
          while i >= 0 && lines[i] =~ /\A\s*#( ?)(.*)\z/
            comment.unshift(Regexp.last_match(2).rstrip)
            i -= 1
          end
          text = comment.take_while { |l| !l.strip.empty? }.join(' ').gsub(/\s+/, ' ').strip
          text[/\A.*?\.(?=\s|\z)/] || text
        rescue SystemCallError
          ''
        end
      end
    end
  end
end
