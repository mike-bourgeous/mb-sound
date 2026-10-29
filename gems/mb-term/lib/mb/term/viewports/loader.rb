require_relative 'tree'
require_relative '../data_file'

module MB
  module Term
    module Viewports
      # Reads layouts saved by Layout#to_ruby (and written by hand): one
      # `layout :name, options do ... end` holding only pane, repl, rows,
      # cols, columns, and tabs calls with literal arguments, walked with
      # DataFile (never eval) and replayed through the same Builder
      # people use.
      module Loader
        LoadError = DataFile::LoadError

        # Options of the layout call itself.
        OPTIONS = %i[focus zoom gap].freeze

        module_function

        # [Layout, extra options] from +text+; +extra+ names other
        # options the caller handles (e.g. the band's :at), returned in
        # the second element.
        def parse(text, path = '(layout)', extra: [])
          calls = DataFile.parse(text, path, calls: { nil => %i[layout], :* => Builder::CALLS })
          raise LoadError, "#{path}: expected one `layout :name do ... end`" unless calls.length == 1 && calls[0].children

          top = calls[0]
          raise LoadError, "#{path}:#{top.line}: layout takes one Symbol name" unless top.args.length == 1 && top.args[0].is_a?(Symbol)

          bad = top.opts.keys - OPTIONS - extra
          unless bad.empty?
            hint = DidYouMean::SpellChecker.new(dictionary: (OPTIONS + extra).map(&:to_s)).correct(bad.first.to_s).first
            raise LoadError, "#{path}:#{top.line}: unknown layout option #{bad.first.inspect}#{hint ? " (did you mean #{hint}:?)" : ''} (#{(OPTIONS + extra).map(&:inspect).join(', ')})"
          end

          kids = top.children
          opts = top.opts.slice(*OPTIONS)
          layout = begin
            Viewports.layout(top.args[0], **opts) { DataFile.replay(self, kids, path) }
          rescue Error => e
            raise LoadError, "#{path}: #{e.message}"
          end
          [layout, top.opts.slice(*extra)]
        end

        # The Layout in +text+ (no extra options allowed).
        def load(text, path = '(layout)')
          parse(text, path).first
        end
      end
    end
  end
end
