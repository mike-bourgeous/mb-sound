require 'did_you_mean'

module MB
  module Sound
    class Form
      # The `flow do ... end` block builder.  The block runs with
      # instance_exec on a BasicObject, so section names never collide with
      # console methods or Pry commands, and every section is a method:
      #
      # - The first call with a length declares the section (defining a
      #   method of that name on this builder) and plays it: `verse 8.bars,
      #   times: 2`.
      # - Later bare calls play it again: `verse` (or `verse times: 2`).
      # - A bare call of a name that was never declared is a NoMethodError
      #   that suggests the closest section names (`vrese` -> verse).
      #
      # Steps that steer the flow (their names can't be section names):
      # - `label :top`: a target for goto (takes no time; also a marker, so
      #   `seek :top` and `at_marker(:top)` work).
      # - `goto :top` (always), `goto :top, times: 2` (twice, then on),
      #   `goto a: 3, b: 1` (a weighted random label; `goto top: 3, next: 1`
      #   carries on one time in four), `goto ->(f) { ... }`
      #   (a Proc given a Form::State, returning a label or nil to carry on).
      # - `pick chorus: 3, drop: 1` / `pick :chorus, :drop` (even odds):
      #   plays one, then carries on.  For groups, a block of options:
      #       pick do |p|
      #         p.option(3) { chorus; chorus }
      #         p.option(1) { drop }
      #         p.option(1) { }          # sometimes nothing
      #       end
      # - `repeat 2 do ... end` repeats a group; `fill :big, every: 16`
      #   adds a phrase fill (see PhraseFill).
      #
      # Section options: +times:+ (passes per play), +fill:+ (see
      # Fill.from), +scene:+ (the scene to launch; the section's name by
      # default, false for none), +fade:+ (bars).
      class Builder < BasicObject
        # The block argument of `pick do |p| ... end`: each #option is one
        # choice (sections called inside its block play in that option).
        class Options < BasicObject
          def initialize(builder)
            @builder = builder
          end

          # Adds a choice with +weight+ (1 by default): the sections played
          # in the block (none without a block, or with an empty one).
          def option(weight = 1, &block)
            @builder.__send__(:__option__, weight, &block)
          end

          def method_missing(name, *_args)
            ::Kernel.raise ::NoMethodError.new("undefined method '#{name}' for a pick's options (use p.option(weight) { sections })", name)
          end

          def respond_to_missing?(_name, _include_private = false)
            false
          end

          def inspect
            '#<MB::Sound::Form::Builder::Options>'
          end
        end

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
          @options = nil
        end

        # Plays the steps in the block +count+ times.
        def repeat(count, &block)
          ::Kernel.raise ::ArgumentError, "repeat needs a positive Integer (got #{count.inspect})" unless count.is_a?(::Integer) && count > 0
          ::Kernel.raise ::ArgumentError, 'repeat needs a block of sections' unless block

          @stack.last << Repeat.new(count: count, steps: __collect__(&block))
          nil
        end

        # Adds a phrase fill (see PhraseFill): fill +name+ for +length+ at
        # the end of every +every+ bars from each section's start.
        def fill(name, every:, length: 1, layer: false)
          @phrase_fills << PhraseFill.new(name: name, every: every, length: length, layer: layer)
          nil
        end

        # Marks a position in the flow that #goto jumps to (takes no time).
        # Labels are unique, and different from section names.
        def label(name)
          ::Kernel.raise ::ArgumentError, "label needs a Symbol name (got #{name.inspect})" unless name.is_a?(::Symbol)
          @stack.last << Label.new(name: name)
          nil
        end

        # Jumps to a label: +target+ is a label, or give labels with weights
        # for a random one (`goto a: 3, b: 1`; `next:` weighs carrying on to
        # the next step: `goto top: 3, next: 1`), or a Proc given a
        # Form::State that returns a label (or nil to carry on).  With
        # +times:+ it jumps that many times, then falls through once (and
        # its count starts over); without, every time.
        def goto(target = nil, times: nil, **weights)
          ::Kernel.raise ::ArgumentError, 'goto takes a label or weighted labels, not both' if target && !weights.empty?
          # nil => w is the same as next: w (carry on), like a Proc's nil
          weights = weights.to_h { |k, w| [k.nil? ? NEXT : k, w] } if weights.key?(nil)
          target ||= weights unless weights.empty?
          ::Kernel.raise ::ArgumentError, 'goto needs a label (goto :top) or weighted labels (goto a: 3, b: 1)' if target.nil?
          Form.check_goto(target, times)
          @stack.last << Goto.new(target: target, times: times)
          nil
        end

        # Plays one of several sections, then carries on: `pick :a, :b`
        # (even odds), `pick a: 3, b: 1` (weights), or a block of options
        # for groups (see the class comment).
        def pick(*names, **weights, &block)
          ::Kernel.raise ::ArgumentError, 'pick takes section names or a block of options, not both' if block && !(names.empty? && weights.empty?)

          options = if block
                      @options, outer = [], @options
                      begin
                        block.call(Options.new(self))
                        @options
                      ensure
                        @options = outer
                      end
                    else
                      bad = names.reject { |n| n.is_a?(::Symbol) }
                      ::Kernel.raise ::ArgumentError, "pick takes section names (got #{bad.map(&:inspect).join(', ')})" unless bad.empty?
                      Form.check_weights('pick', weights) unless weights.empty?
                      (names.map { |n| [n, 1] } + weights.to_a).map { |n, w|
                        __adopt__(n)
                        Option.new(weight: w, steps: [Play.new(name: n, times: nil)].freeze)
                      }
                    end
          ::Kernel.raise ::ArgumentError, 'pick needs at least one option (pick a: 3, b: 1, or p.option(w) { ... } in a block)' if options.empty?

          @stack.last << Pick.new(options: options.freeze)
          nil
        end

        # Plays sections drawn from +source+ (a markov or lsystem; see
        # Form::Generate) as the flow plays: one per pass, each decided at
        # the commit point before it, until the source ends (or +sections+
        # per visit).  +bars:+ (or keywords) gives sections their lengths
        # (bars, Durations, Ranges of bars or Arrays drawn per occurrence),
        # declaring the ones the flow hasn't declared:
        #
        #     label :top
        #     generate moods, still: 6, drift: 4..8, bloom: [8, 12]
        #     goto :top
        def generate(source, bars: {}, sections: nil, **lengths)
          lengths = bars.merge(lengths)
          step = Generate.new(source: source, lengths: lengths, sections: sections)
          lengths.each do |name, spec|
            __adopt__(name)
            next if @sections.key?(name)
            ::Kernel.raise ::ArgumentError, "generate: #{name.inspect} can't be a section name" if (STEP_NAMES + SOURCE_NAMES).include?(name)
            @sections[name] = Section.new(name: name, length: Form.default_length(spec))
            __define__(name)
          end
          @stack.last << step
          nil
        end

        # Sources and params for generate steps, so a printed flow
        # (`generate markov(...), bars: { ... }`) builds again as it reads:
        # these call MB::Sound's methods (and can't be section names).
        def markov(*args, **kwargs)
          ::MB::Sound.markov(*args, **kwargs)
        end

        def lsystem(*args, **kwargs)
          ::MB::Sound.lsystem(*args, **kwargs)
        end

        def knob(*args, **kwargs)
          ::MB::Sound.knob(*args, **kwargs)
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
            __adopt__(name)
            return __play__(name, options)
          end

          if args.length == 1 && Form.length?(args.first)
            __check_options__(name, options)
            section = Section.new(
              name: name,
              length: args.first,
              times: options.fetch(:times, 1),
              fill: Fill.from(options[:fill], section: name),
              scene: options[:scene],
              fade: options[:fade],
              knobs: Form.section_options(name, options)[1]
            )

            @sections[name] = section
            __define__(name)
            @stack.last << Play.new(name: name, times: nil)
            return nil
          end

          hint = Form.suggest(name, (@sections.keys + @known.keys + STEP_NAMES).uniq, symbols: false)
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

        # Raises for options a section declaration doesn't take (with a
        # pointer to goto/pick for the removed next:).
        def __check_options__(name, options)
          if options.key?(:next)
            ::Kernel.raise ::ArgumentError, "#{name}: sections no longer take next: (what follows belongs to the flow): " \
              "write `goto :label` after the section (with `label :label` at the target), or `pick a: 3, b: 1`; the form ends after its last step"
          end
          Form.section_options(name, options)
        end

        # Makes a section declared outside the block (Arrangement#section)
        # part of this form and callable.
        def __adopt__(name)
          return unless @known.key?(name) && !@sections.key?(name)
          @sections[name] = @known[name]
          __define__(name)
        end

        # Runs +block+ collecting the steps it adds.  Returns them (frozen).
        def __collect__(&block)
          steps = []
          @stack.push(steps)
          begin
            block.call
          ensure
            @stack.pop
          end
          steps.freeze
        end

        # Adds a pick option (see Options#option).
        def __option__(weight, &block)
          ::Kernel.raise ::ArgumentError, 'p.option only works inside its pick block' if @options.nil?
          ::Kernel.raise ::ArgumentError, "pick option weights are numbers of at least 0 (got #{weight.inspect})" unless weight.is_a?(::Numeric) && weight >= 0
          @options << Option.new(weight: weight, steps: block ? __collect__(&block) : [].freeze)
          nil
        end

        # Defines a method for section +name+ on this builder: bare calls
        # play it again (+times:+ allowed), calls with a length raise.
        def __define__(name)
          builder = self
          sc = (class << self; self; end)
          return if sc.method_defined?(name)

          sc.define_method(name) do |*args, **options|
            # Again with a length: plays it for that length this time (the
            # same declaration again plays it as declared)
            next builder.__send__(:__replay__, name, args, options) unless args.empty?
            unknown = options.keys - [:times]
            ::Kernel.raise ::ArgumentError, "#{name}: a repeated section only takes times: (got #{unknown.map(&:inspect).join(', ')}); give other options where it is declared" unless unknown.empty?
            builder.__send__(:__play__, name, options)
          end
        end

        # Plays declared section +name+ again with a length (+args+): for
        # that length this time (G4: `chorus 16` ... `chorus 8`), with
        # +times:+ for this play.  Other options must be as declared (they
        # belong to the section wherever it plays); options left out keep
        # the declaration's.
        def __replay__(name, args, options)
          unless args.length == 1 && Form.length?(args.first)
            ::Kernel.raise ::ArgumentError, "#{name}: the first argument must be a length (got #{args.first.inspect}); call it bare to play it as declared"
          end
          __check_options__(name, options)
          s = @sections[name]
          knobs = Form.section_options(name, options)[1]
          differ = []
          differ << :fill if options.key?(:fill) && Fill.from(options[:fill], section: name) != s.fill
          differ << :scene if options.key?(:scene) && options[:scene] != s.scene
          differ << :fade if options.key?(:fade) && options[:fade] != s.fade
          differ.concat(knobs.keys.reject { |k| s.knobs.key?(k) && s.knobs[k] == knobs[k] })
          unless differ.empty?
            ::Kernel.raise ::ArgumentError, "#{name} is already declared with other #{differ.map { |k| "#{k}:" }.join(', ')}; " \
              "a section plays the same way wherever it appears (only its length and times: may change: `#{name} 4` or `#{name} times: 2`), " \
              'so give the other version its own name'
          end
          length = Form.same_length?(args.first, s.length) ? nil : args.first
          times = options[:times]
          times = nil if times == s.times
          __play__(name, { times: times }, length: length)
        end

        def __play__(name, options, length: nil)
          times = options[:times]
          ::Kernel.raise ::ArgumentError, "#{name}: times: must be a positive Integer (got #{times.inspect})" unless times.nil? || (times.is_a?(::Integer) && times > 0)
          @stack.last << Play.new(name: name, times: times, length: length)
          nil
        end
      end
    end
  end
end
