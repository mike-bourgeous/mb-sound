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
            dsl + classes
          end
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

        # Example lines from a module's own comment (the block after a line
        # starting "Example", or indented lines).
        def module_examples(mod)
          DocIndex.examples_in(module_comment(mod))
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
          (console_methods + dsl_methods).select { |e| e.name == name }
        end

        private

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
