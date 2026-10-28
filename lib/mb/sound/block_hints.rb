module MB
  module Sound
    # Hints for errors raised inside chain and patch blocks written as if
    # they had an implicit receiver or a parameter they don't name
    # (omnibus15, from the maintainer's take of 2026-10-27: `master {
    # reverb }`, `master { softclip(0, 1) }`, `track(:bass) { preset
    # :dnb_reese, midi: clip }`): a block's code runs in the console's
    # scope, so `reverb` there is a call on MB::Sound, not on the mix.
    #
    #     BlockHints.hint(e, call: 'master', param: 'mix')
    #     # => "reverb is a method of the signal: use it, `master { it.reverb }`, or name it: `master { |mix| mix.reverb }`"
    module BlockHints
      # Block parameter names people reach for without naming them.
      PARAM_NAMES = %i[clip midi notes sig mix input signal kit].freeze

      module_function

      # A one-line hint for NameError +e+ raised by a block of +call+ (the
      # command, e.g. "master", "bus(:verb)", "track(:bass)") whose
      # parameter is +param+ (its usual name), or nil when +e+ isn't one
      # of these mistakes.
      def hint(e, call:, param:)
        return nil unless e.is_a?(NameError) && console_receiver?(e)
        name = e.name
        if PARAM_NAMES.include?(name)
          return "#{name} isn't defined in the block: name the block's parameter, `#{call} { |#{name}| ... }`, or use `it`"
        end
        return nil unless signal_method?(name)
        args = e.is_a?(NoMethodError) && e.args && !e.args.empty? ? "(#{e.args.map(&:inspect).join(', ')})" : ''
        "#{name} is a method of the signal: use it, `#{call} { it.#{name}#{args} }`, or name it: `#{call} { |#{param}| #{param}.#{name}#{args} }`"
      end

      # +e+ with the hint added (an ArgumentError naming the original, so
      # ErrorFormat prints one line), or +e+ itself when there is none.
      def with_hint(e, call:, param:)
        h = hint(e, call: call, param: param) or return e
        ArgumentError.new("#{call} block: #{h}").tap { |x| x.set_backtrace(e.backtrace || []) }
      end

      # True if +e+ was raised for a call on the console's own scope
      # (MB::Sound, or the top-level object).
      def console_receiver?(e)
        r = e.receiver
        r.equal?(MB::Sound) || r.equal?(TOPLEVEL_BINDING.receiver) || (r.is_a?(Module) && r.name.to_s.start_with?('MB::Sound'))
      rescue ArgumentError
        false
      end

      # True if +name+ is a DSL method of signals (nodes or bundles).
      def signal_method?(name)
        GraphNode.method_defined?(name) || GraphNode::Channels.method_defined?(name) || Tone.method_defined?(name)
      end
    end
  end
end
