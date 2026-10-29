module MB
  module Sound
    module UI
      # Pane kinds and pane files.  A pane kind is Ruby (library code, or a
      # block given to UI.pane_kind at the console) that makes a Pane from
      # options; a pane file is data naming kinds with literal options,
      # read with DataFile (never eval) from UI.layouts_dir/panes/*.rb and
      # reloaded when a file changes:
      #
      #     # ~/.local/share/mb-sound/ui/panes/mine.rb
      #     pane :mix, kind: :meters, title: 'mix', rate: 30
      #     pane :notes, kind: :text, lines: ['drop at 33', 'breakdown at 49'], role: :name
      #     pane :cutoff, kind: :knob, knob: :cut
      #
      # Built-in kinds: the built-in panes (:transport, :form, :tracks,
      # :queue, :knobs, :meters, :cpu, :scope with look:; the sound-design
      # screen's :inspector, :preview, :code, :audition, :render), :text (lines:,
      # role:), and :knob (knob: one knob, large).  Every kind takes rate:,
      # height:, width:, title:.
      module PaneFiles
        # A pane of text lines (kind :text).
        class TextPane < Pane
          def initialize(name, lines: [], role: :text, **opts)
            raise ArgumentError, 'lines: is an Array of Strings' unless lines.is_a?(Array) && lines.all?(String)
            super(name, rate: 1, height: [lines.length, 1].max, width: [lines.map(&:length).max.to_i, 10].max, **opts)
            @lines = lines.map(&:freeze).freeze
            @role = role
          end

          def draw_body(c, _s, _state)
            @lines.first(c.h).each { |l| c.puts [l, @role] }
          end
        end

        # One knob, large: its name, value, and a meter across the pane
        # (kind :knob).
        class KnobPane < Pane
          def initialize(name, knob:, **opts)
            raise ArgumentError, "knob: is a knob name (a Symbol; got #{knob.inspect})" unless knob.is_a?(Symbol)
            super(name, rate: 30, height: 2, width: 24, **opts)
            @knob = knob
          end

          def draw_body(c, s, _state)
            k = s&.knobs&.find { |kv| kv.name == @knob }
            unless k
              c.puts [@knob.to_s, :name], [' (no such knob yet)', :dim]
              return
            end
            spec = k.spec
            c.puts [@knob.to_s, :name], ' ', ["#{Panes.fmt(k.value)}#{spec.unit ? " #{spec.unit}" : ''}", :key]
            c.meter(spec.position(k.value).to_f, width: c.w, role: :key) if c.h > 1
          end
        end

        # Options every kind takes (Pane#configured).
        COMMON = Pane::CONFIG

        module_function

        # The kinds: {kind => Proc(name, **opts) -> Pane}.
        def kinds
          @kinds ||= begin
            builtin = {
              transport: Panes::Transport, form: Panes::Form, tracks: Panes::Tracks, queue: Panes::Queue,
              knobs: Panes::Knobs, meters: Panes::Meters, cpu: Panes::CPU,
              inspector: Panes::Inspector, preview: Panes::Preview, code: Panes::Code, audition: Panes::Audition, render: Panes::Render,
            }.to_h { |k, cls| [k, ->(name, **o) { cls.new.configured(name, **o) }] }
            builtin[:scope] = ->(name, look: nil, **o) { Panes::Scope.new(name, look: look).configured(name, **o) }
            builtin[:text] = ->(name, **o) { TextPane.new(name, **o) }
            builtin[:knob] = ->(name, **o) { KnobPane.new(name, **o) }
            builtin
          end
        end

        # A Pane of +kind+ named +name+.
        def build(name, kind:, **opts)
          maker = kinds.fetch(kind) {
            hint = DidYouMean::SpellChecker.new(dictionary: kinds.keys.map(&:to_s)).correct(kind.to_s).first
            raise ArgumentError, "No pane kind #{kind.inspect}#{hint ? " (did you mean :#{hint}?)" : ''} (kinds: #{kinds.keys.map(&:inspect).join(', ')})"
          }
          maker.call(name, **opts)
        end

        # Where pane files live.
        def dir
          File.join(UI.layouts_dir, 'panes')
        end

        # Loads (or reloads) pane files that changed since they were read,
        # defining their panes.  Errors go to +errors+ ([path:line message],
        # the old definitions stay).  Returns the names defined.
        def reload(errors = [])
          @mtimes ||= {}
          defined = []
          Dir.glob(File.join(dir, '*.rb')).sort.each do |path|
            m = File.mtime(path)
            next if @mtimes[path] == m
            @mtimes[path] = m
            begin
              defined.concat(load_file(path))
            rescue MB::Term::DataFile::LoadError => e
              errors << e.message
            end
          end
          defined
        end

        # The panes of one file (defined in UI.panes).  Returns their names.
        def load_file(path)
          calls = MB::Term::DataFile.load(path, calls: { nil => %i[pane] })
          panes = calls.map do |c|
            unless c.args.length == 1 && c.args[0].is_a?(Symbol) && c.children.nil?
              raise MB::Term::DataFile::LoadError, "#{path}:#{c.line}: expected `pane :name, kind: :meters, ...`"
            end
            raise MB::Term::DataFile::LoadError, "#{path}:#{c.line}: pane #{c.args[0].inspect} needs kind:" unless c.opts.key?(:kind)
            begin
              build(c.args[0], **c.opts)
            rescue ArgumentError => e
              raise MB::Term::DataFile::LoadError, "#{path}:#{c.line}: #{e.message}"
            end
          end
          panes.each { |p| UI.define_pane_object(p) }
          panes.map(&:name)
        end
      end
    end
  end
end
