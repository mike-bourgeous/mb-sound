require 'method_source'

module MB
  module Sound
    module Help
      # Reads the console surface and its doc comments from the code, so help
      # text is generated rather than copied (see the README's staleness
      # section).  Nothing here is hand-maintained except Help::Topics.
      class DocIndex
        # One documented method: +owner+ is the module that defines it,
        # +surface+ a label for the inventory (console, GraphNode DSL, a
        # class), +original+ the aliased name (nil for primary names).
        Entry = Struct.new(:name, :owner, :surface, :original, :unbound, keyword_init: true) do
          def alias? = !original.nil?

          # The doc comment without '#' markers (String, maybe empty).
          def comment
            @comment ||= begin
              unbound.comment.lines.map { |l| l.sub(/^\s*# ?/, '') }.join
            rescue MethodSource::SourceNotFoundError, NoMethodError
              ''
            end
          end

          def documented? = !comment.strip.empty?

          # Code lines from the comment: indented example blocks (4+ spaces
          # after the #) and `backticked calls` that look like code.
          def examples
            @examples ||= DocIndex.examples_in(comment)
          end

          def example? = examples.any?

          # The first sentence of the comment, for one-line listings.
          def summary
            s = comment.split(/\n\s*\n/).first.to_s.gsub(/\s+/, ' ').strip
            s = s.split(/(?<=[a-z0-9)`'])(?<!e\.g)(?<!i\.e)\.(\s|$)/).first.to_s
            s = s.gsub(/\+(\w+:?)\+/, '\1')
            s.length > 110 ? s[0, 107] + '...' : s
          end

          # A Ruby-looking signature from the parameters: `turn(name, value = nil, at:, ...)`.
          def signature
            params = unbound.parameters.map { |type, n|
              case type
              when :req then n.to_s
              when :opt then "#{n} = ..."
              when :rest then "*#{n}"
              when :keyreq then "#{n}:"
              when :key then "#{n}:"
              when :keyrest then "**#{n}"
              when :block then "&#{n}"
              end
            }.compact
            params.empty? ? name.to_s : "#{name}(#{params.join(', ')})"
          end

          def location = unbound.source_location
        end

        # Skips Recipe's recorders (anonymous prepended modules) to reach
        # the documented method.
        def self.unwrap(um)
          um = um.super_method while um.owner.name.nil? && um.super_method
          um
        end

        def self.examples_in(text)
          lines = []
          text.each_line do |l|
            m = l.match(/^ {4,}(\S.*)$/)
            lines << m[1].rstrip if m && m[1] !~ /^[-*] /
          end
          text.scan(/`([^`\n]{4,})`/).flatten.each do |code|
            lines << code if code =~ /[(.]|\s\d|:\w/ && code !~ /\A[A-Z][\w:]*\z/
          end
          lines.uniq
        end

        # The console modules MB::Sound extends itself with (in order).
        def console_modules
          MB::Sound.singleton_class.ancestors
            .take_while { |m| m != Module }
            .select { |m| m.is_a?(Module) && !m.is_a?(Class) && m.name&.start_with?('MB::Sound::') && m.name.end_with?('Methods') }
            .reverse
        end

        def console_methods
          @console_methods ||= console_modules.flat_map { |mod| entries_for(mod, 'console') }
        end

        # The per-node DSL (GraphNode::*Methods modules) plus the classes
        # with their own recorded surfaces.
        def dsl_methods
          @dsl_methods ||= begin
            gn = GraphNode.included_modules.select { |m| m.name&.start_with?('MB::Sound::GraphNode::') && m.name.end_with?('Methods') }
            dsl = gn.flat_map { |mod| entries_for(mod, 'GraphNode DSL') }
            surf = GraphNode::Recipe::Surface
            dsl = dsl.select { |e| surf.graph_node_dsl.include?(e.name) }
            classes = surf.classes.flat_map { |c|
              names = surf.own_surface(c) | surf.mixin_surface(c)
              names.map { |n|
                um = DocIndex.unwrap(c.instance_method(n))
                Entry.new(name: n, owner: c, surface: c.name.sub('MB::Sound::', ''), original: (um.original_name == n ? nil : um.original_name), unbound: um)
              }
            }
            dsl + classes + builder_methods(dsl + classes)
          end
        end

        # Classes whose documented public methods are help entries though
        # they aren't recorded DSL (omnibus19; Kez, panel 3: `help :voice`
        # found only Sampler::Instrument#voice, `help :body`/`:metal`/`:lofi`
        # fell back to searches, `help :stretch` had no Sample#stretch):
        # the `kit { }` builder and its voices' layers, and Sample's views,
        # which print through their lineage.
        BUILDER_CLASSES = %w[MB::Sound::Drums::Builder MB::Sound::Drums::Hit MB::Sound::Sample].freeze

        # Where an entry sorts among others of its name (lower first):
        # console, node DSL, builders and views people write (above), other
        # surfaces; undocumented ones last (see #find_all).
        def rank(entry)
          base = case entry.surface
                 when 'console' then 0
                 when 'GraphNode DSL' then 1
                 else BUILDER_CLASSES.include?(entry.owner.name) ? 2 : 3
                 end
          entry.documented? ? base : base + 10
        end

        def numeric_methods
          mods = Numeric.ancestors.select { |m| m.name&.start_with?('MB::') }
          mods.flat_map { |m| m.public_instance_methods(false) }.uniq.sort
        end

        def pry_commands
          Pry.config.commands.list_commands.map(&:to_s)
        end

        # Console method names that a Pry command shadows.
        def collisions
          names = console_methods.map { |e| e.name.to_s }
          pry_commands & names
        end

        # The comment above `module Name` in the file defining +mod+'s
        # methods (method_source doesn't read module comments).
        def module_comment(mod)
          @module_comments ||= {}
          @module_comments[mod] ||= begin
            m = mod.instance_methods(false).first || mod.private_instance_methods(false).first
            file = m && mod.instance_method(m).source_location&.first
            if file && File.exist?(file)
              lines = File.readlines(file)
              short = mod.name.split('::').last
              i = lines.index { |l| l =~ /^\s*module #{short}\b/ }
              com = []
              j = i ? i - 1 : -1
              while j >= 0 && lines[j] =~ /^\s*#/
                com.unshift(lines[j].sub(/^\s*# ?/, ''))
                j -= 1
              end
              com.join
            else
              ''
            end
          end
        end

        # Finds a console or DSL entry by name.
        def find(name)
          name = name.to_sym
          console_methods.find { |e| e.name == name } || dsl_methods.find { |e| e.name == name }
        end

        # All entries named +name+ (a name can be both a console command and
        # a node method, e.g. delay or reverb).
        def find_all(name)
          name = name.to_sym
          (console_methods + dsl_methods).select { |e| e.name == name }.each_with_index.sort_by { |e, i| [rank(e), i] }.map(&:first)
        end

        private

        # Documented public methods of BUILDER_CLASSES not already in
        # +entries+.
        def builder_methods(entries)
          have = entries.map { |e| [e.owner, e.name] }.to_h { |k| [k, true] }
          BUILDER_CLASSES.flat_map { |name|
            c = Object.const_get(name)
            c.public_instance_methods(false).sort.filter_map { |n|
              next if have[[c, n]] || n.to_s.end_with?('=') || n.to_s.start_with?('plan_')
              um = DocIndex.unwrap(c.instance_method(n))
              e = Entry.new(name: n, owner: c, surface: name.sub('MB::Sound::', ''), original: (um.original_name == n ? nil : um.original_name), unbound: um)
              e if e.documented?
            }
          }
        end

        def entries_for(mod, surface)
          mod.public_instance_methods(false).sort.map { |n|
            um = mod.instance_method(n)
            Entry.new(name: n, owner: mod, surface: surface, original: (um.original_name == n ? nil : um.original_name), unbound: um)
          }
        end
      end
    end
  end
end
