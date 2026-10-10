require 'did_you_mean'

module MB
  module Sound
    class Form
      # The `flow do ... end` block builder.  The block runs with
      # instance_exec on a BasicObject, so section names never collide with
      # console methods or Pry commands, and every section is a method:
      #
      # - The first call with a length declares the section (defining a
      #   method of that name on this builder) and plays it:
      #   `verse 8.bars, times: 2, next: { chorus: 3, drop: 1 }`.
      # - Later bare calls play it again: `verse` (or `verse times: 2`).
      # - A bare call of a name that was never declared is a NoMethodError
      #   that suggests the closest section names (`vrese` -> verse).
      # - `repeat 2 do ... end` repeats a group; `fill :big, every: 16`
      #   adds a phrase fill (see PhraseFill).
      #
      # Section options: +times:+ (passes per play), +next:+ (follow action:
      # :next, :again, :end, a section name, a Hash of weights such as `{
      # chorus: 3, drop: 1 }`, or a Proc given a Form::State), +fill:+ (see
      # Fill.from), +scene:+ (the scene to launch; the section's name by
      # default, false for none), +fade:+ (bars).
      class Builder < BasicObject
        # Builds a Form from the block.  +sections+ are sections declared
        # elsewhere (Arrangement#section) that bare calls can play.
        def self.build(sections: {}, &block)
          ::Kernel.raise ::ArgumentError, 'Pass a block to build a form (flow do ... end)' unless block

          b = new(sections)
          b.instance_exec(&block)
          b.__form__
        end

        def initialize(sections)
          @known = sections.dup
          @sections = {}
          @order = []
          @phrase_fills = []
          @stack = [@order]
        end

        # Plays the steps in the block +count+ times.
        def repeat(count, &block)
          ::Kernel.raise ::ArgumentError, "repeat needs a positive Integer (got #{count.inspect})" unless count.is_a?(::Integer) && count > 0
          ::Kernel.raise ::ArgumentError, 'repeat needs a block of sections' unless block

          steps = []
          @stack.push(steps)
          begin
            block.call
          ensure
            @stack.pop
          end
          @stack.last << Repeat.new(count: count, steps: steps.freeze)
          nil
        end

        # Adds a phrase fill (see PhraseFill): fill +name+ for +length+ at
        # the end of every +every+ bars from each section's start.
        def fill(name, every:, length: 1, layer: false)
          @phrase_fills << PhraseFill.new(name: name, every: every, length: length, layer: layer)
          nil
        end

        # The Form built so far.  (Named so it can't be a section name.)
        def __form__
          Form.new(sections: @sections, order: @order, phrase_fills: @phrase_fills)
        end

        # Declares a section on its first call with a length (defining a
        # method for it), and raises a NoMethodError with suggestions for
        # bare calls of unknown names.
        def method_missing(name, *args, **options, &block)
          if args.empty? && @known.key?(name)
            # A section declared outside the block
            @sections[name] ||= @known[name]
            __define__(name)
            return __play__(name, options)
          end

          if args.length == 1 && Form.length?(args.first)
            section = Section.new(
              name: name,
              length: args.first,
              times: options.fetch(:times, 1),
              next_action: options.fetch(:next, :next),
              fill: Fill.from(options[:fill], section: name),
              scene: options[:scene],
              fade: options[:fade]
            )
            unknown = options.keys - [:times, :next, :fill, :scene, :fade]
            ::Kernel.raise ::ArgumentError, "#{name}: unknown options #{unknown.map(&:inspect).join(', ')} (use times:, next:, fill:, scene:, fade:)" unless unknown.empty?

            @sections[name] = section
            __define__(name)
            @stack.last << Play.new(name: name, times: nil)
            return nil
          end

          names = (@sections.keys + @known.keys).uniq.map(&:to_s)
          suggestions = ::DidYouMean::SpellChecker.new(dictionary: names).correct(name.to_s)
          hint = suggestions.empty? ? '' : "\nDid you mean?  #{suggestions.join("\n                ")}"
          detail = args.empty? ? 'give its length the first time (e.g. `' + name.to_s + ' 8.bars`)' : "the first argument must be a length (got #{args.first.inspect})"
          ::Kernel.raise ::NoMethodError.new("undefined section '#{name}' in flow: #{detail}#{hint}", name)
        end

        def respond_to_missing?(_name, _include_private = false)
          false
        end

        def inspect
          "#<MB::Sound::Form::Builder #{@sections.keys.join(' ')}>"
        end

        private

        # Defines a method for section +name+ on this builder: bare calls
        # play it again (+times:+ allowed), calls with a length raise.
        def __define__(name)
          builder = self
          sc = (class << self; self; end)
          return if sc.method_defined?(name)

          sc.define_method(name) do |*args, **options|
            unless args.empty?
              # The same declaration again just plays it again
              same = builder.__send__(:__same__?, name, args, options)
              ::Kernel.raise ::ArgumentError, "#{name} is already declared differently; call it bare to play it again (`#{name}` or `#{name} times: 2`)" unless same
              next builder.__send__(:__play__, name, {})
            end
            unknown = options.keys - [:times]
            ::Kernel.raise ::ArgumentError, "#{name}: a repeated section only takes times: (got #{unknown.map(&:inspect).join(', ')}); give other options where it is declared" unless unknown.empty?
            builder.__send__(:__play__, name, options)
          end
        end

        # True if +args+ and +options+ declare section +name+ exactly as it
        # was declared.
        def __same__?(name, args, options)
          s = @sections[name]
          args.length == 1 && args.first == s.length && s.times == options.fetch(:times, 1) &&
            s.next_action == options.fetch(:next, :next) && s.fill == Fill.from(options[:fill], section: name) &&
            s.scene == options[:scene] && s.fade == options[:fade] && (options.keys - [:times, :next, :fill, :scene, :fade]).empty?
        end

        def __play__(name, options)
          times = options[:times]
          ::Kernel.raise ::ArgumentError, "#{name}: times: must be a positive Integer (got #{times.inspect})" unless times.nil? || (times.is_a?(::Integer) && times > 0)
          @stack.last << Play.new(name: name, times: times)
          nil
        end
      end
    end
  end
end
