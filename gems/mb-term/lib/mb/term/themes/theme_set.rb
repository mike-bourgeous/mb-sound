require_relative '../data_file'

module MB
  module Sound
    module UI
      # Themes: colors by role and glyph sets, chosen with `ui.theme
      # :phosphor` (or Themes.use), defined in Ruby (Themes.define) or in
      # theme files, which are data read by DataFile (never eval):
      #
      #     theme :mine, based_on: :default do
      #       role :title, '#9ef01a', bold: true   # truecolor (shown in 256/16 colors as the screen needs)
      #       role :dim, 245                       # a palette index (the terminal's own palette)
      #       role :warn, :yellow                  # one of the 16 named colors
      #       glyphs :unicode do
      #         play '▶'
      #         rec '●'
      #       end
      #       glyphs :ascii do
      #         play '>'
      #       end
      #     end
      #
      # Roles a pane uses: :text, :dim, :title, :name, :key, :ok, :warn,
      # :bad, :rec, :armed, :queued, :low, :mid, :high.  Glyph sets: :unicode
      # and :ascii (always complete: missing glyphs come from the base
      # theme).  Generic (no MB::Sound types).
      module Themes
        # A theme: +roles+ ({role => [color, bold]}, color an [r, g, b] or
        # a palette index) and +glyphs+ ({:unicode => {...}, :ascii => {...}}).
        Theme = Data.define(:name, :roles, :glyphs) do
          def inspect = "#<UI::Themes::Theme #{name.inspect} #{roles.length} roles>"
        end

        # The 16 named colors as palette indexes.
        NAMED = %i[black red green yellow blue magenta cyan white
                   bright_black bright_red bright_green bright_yellow bright_blue bright_magenta bright_cyan bright_white]
          .each_with_index.to_h.freeze

        # Glyph names a theme may set.
        GLYPH_NAMES = %i[play will stop on off armed rec queued sep arrow rule hrule].freeze

        # Theme file calls by block level (a closed table: glyph names too).
        CALLS = { nil => %i[theme], theme: %i[role glyphs], glyphs: GLYPH_NAMES }.freeze

        # Builds a theme from its block (`role`, `glyphs`).
        class Builder
          attr_reader :roles, :glyph_sets

          def initialize(base)
            @roles = base.roles.dup
            @glyph_sets = base.glyphs.transform_values(&:dup)
          end

          # A role's color: '#rrggbb', [r, g, b], a palette index 0..255, or
          # a named color (:red, :bright_blue, ...); +bold+.
          def role(name, color, bold: false)
            raise ArgumentError, "Role names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            @roles[name] = [Themes.color(color), bold].freeze
            nil
          end

          # Glyphs of set +set+ (:unicode or :ascii): `play '▶'` per glyph.
          def glyphs(set, &block)
            raise ArgumentError, "Glyph sets are :unicode and :ascii (got #{set.inspect})" unless %i[unicode ascii].include?(set)
            g = GlyphBuilder.new(@glyph_sets[set])
            g.instance_exec(&block) if block
            nil
          end
        end

        # `play '>'` calls, one method per name in GLYPH_NAMES (so a typo
        # is a NoMethodError with suggestions).
        class GlyphBuilder
          def initialize(set)
            @set = set
          end

          GLYPH_NAMES.each do |name|
            define_method(name) do |glyph|
              raise ArgumentError, "A glyph is a String: `#{name} '>'` (got #{glyph.inspect})" unless glyph.is_a?(String) && !glyph.empty?
              @set[name] = glyph.dup.freeze
              nil
            end
          end
        end

        module_function

        # [r, g, b] or a palette index for a theme color.
        def color(c)
          case c
          when Array
            raise ArgumentError, "Colors are [r, g, b] with 0..255 (got #{c.inspect})" unless c.length == 3 && c.all? { |v| v.is_a?(Integer) && v.between?(0, 255) }
            c.dup.freeze
          when Integer
            raise ArgumentError, "Palette indexes are 0..255 (got #{c})" unless c.between?(0, 255)
            c
          when /\A#(\h\h)(\h\h)(\h\h)\z/ then [$1.hex, $2.hex, $3.hex].freeze
          when Symbol
            NAMED.fetch(c) {
              hint = DidYouMean::SpellChecker.new(dictionary: NAMED.keys.map(&:to_s)).correct(c.to_s).first
              raise ArgumentError, "No color #{c.inspect}#{hint ? " (did you mean :#{hint}?)" : ''}"
            }
          else
            raise ArgumentError, "Colors are '#rrggbb', [r, g, b], a palette index, or a color name (got #{c.inspect})"
          end
        end

        # The themes by name.
        def all
          @all ||= {}
        end

        # The theme in use.
        def current
          @current || all.fetch(:default)
        end

        # Uses theme +name+ (a Theme, or a name defined, built in, or in
        # .dir).  Returns the Theme.
        def use(name)
          @current = name.is_a?(Theme) ? name : named(name)
        end

        # The theme named +name+.
        def named(name)
          return all[name] if all.key?(name) && !changed?(name)
          path = file_for(name)
          return load_file(path) if path
          hint = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s).first
          raise ArgumentError, "No theme #{name.inspect}#{hint ? " (did you mean :#{hint}?)" : ''} (themes: #{names.map(&:inspect).join(', ')})"
        end

        # Theme names (defined and in .dir).
        def names
          (all.keys + (dir ? Dir.glob(File.join(dir, '*.rb')).map { |f| File.basename(f, '.rb').to_sym } : [])).uniq
        end

        # Where theme files live (nil: none; a Proc is called each time).
        def dir
          @dir.respond_to?(:call) ? @dir.call : @dir
        end

        def dir=(d)
          @dir = d
        end

        # Defines a theme from a block (see Builder).
        def define(name, based_on: :default, &block)
          raise ArgumentError, "Theme names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          base = name == based_on && !all.key?(name) ? nil : named(based_on)
          b = Builder.new(base || Theme.new(name: :empty, roles: {}, glyphs: { unicode: {}, ascii: {} }))
          b.instance_exec(&block) if block
          t = Theme.new(name: name, roles: b.roles.freeze, glyphs: b.glyph_sets.transform_values(&:freeze).freeze)
          all[name] = t
          @current = t if @current&.name == name
          t
        end

        # Loads a theme file (data; see the module comment).  Returns the
        # Theme.
        def load_file(path)
          calls = DataFile.load(path, calls: CALLS)
          raise DataFile::LoadError, "#{path}: expected one `theme :name do ... end`" unless calls.length == 1 && calls[0].children
          top = calls[0]
          raise DataFile::LoadError, "#{path}:#{top.line}: theme takes one Symbol name" unless top.args.length == 1 && top.args[0].is_a?(Symbol)
          bad = top.opts.keys - [:based_on]
          raise DataFile::LoadError, "#{path}:#{top.line}: unknown theme option #{bad.first.inspect} (based_on:)" unless bad.empty?
          kids = top.children
          t = begin
            define(top.args[0], **top.opts) { DataFile.replay(self, kids, path) }
          rescue ArgumentError => e
            raise DataFile::LoadError, "#{path}: #{e.message}"
          end
          (@mtimes ||= {})[top.args[0]] = [path, File.mtime(path)]
          t
        end

        # Reloads the current theme if its file changed.  Returns true if
        # it did.
        def reload_changed
          name = current.name
          return false unless changed?(name)
          use(load_file(file_for(name)))
          true
        end

        def file_for(name)
          return nil unless dir
          path = File.join(dir, "#{name}.rb")
          File.file?(path) ? path : nil
        end

        def changed?(name)
          path, mtime = (@mtimes || {})[name]
          path && File.file?(path) && File.mtime(path) != mtime
        end

        # The color of +role+ ([r, g, b], a palette index, or nil).
        def rgb(role)
          return nil if role.nil?
          return role if role.is_a?(Array) || role.is_a?(Integer)
          current.roles.fetch(role) { raise ArgumentError, "Unknown UI color role #{role.inspect} (#{current.roles.keys.map(&:inspect).join(', ')})" }[0]
        end

        # True if +role+ is bold.
        def bold?(role)
          role.is_a?(Symbol) && current.roles[role]&.[](1) == true
        end

        # The glyph set +set+ of the current theme.
        def glyphs(set)
          current.glyphs.fetch(set)
        end
      end
    end
  end
end
