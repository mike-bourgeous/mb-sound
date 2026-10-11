module MB
  module Sound
    module GraphIO
      # Runtime blocks outside the safe subset, for documents loaded with
      # `trust: :code` (off by default): the block's saved source runs as
      # Ruby.  This is the one place graph documents reach Ruby's eval, and
      # only for blocks the safe subset rejected, after a warning.
      module TrustedCode
        # A proc (or lambda) from block source text +source+ (`{ |x| ... }`
        # or `->(x) { ... }`), with +path+ and +line+ for backtraces.
        def self.block(source, lambda:, path:, line:)
          warn "#{path}:#{line}: trust: :code runs this block's saved Ruby source"
          code = lambda ? source : "proc #{source}"
          pr = isolated_binding.eval(code, path.to_s, line)
          pr.define_singleton_method(:graph_io_source) { source }
          pr
        end

        # A binding with no local variables.
        def self.isolated_binding
          binding
        end
      end
    end
  end
end
