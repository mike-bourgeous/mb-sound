module MB
  module Sound
    # One way to print errors for people (ux-fix-1, 2026-10-18), used by the
    # console's exception handler (bin/sound.rb) and the script runner:
    #
    #     NoMethodError: undefined method 'plya' (did you mean play?)
    #
    # A typo at the prompt or an error mb-sound raised on purpose (a bad
    # argument, a missing file, no sound card) is one line plus its
    # suggestions; errors that usually mean a bug when raised inside the
    # library (NoMethodError, TypeError, ...) keep their backtrace, without
    # Pry's and bin/sound.rb's frames.  In the console, Pry's `wtf?` shows
    # the last error's full backtrace.
    module ErrorFormat
      # Error classes that point to a bug when raised inside mb-sound or a
      # gem (KeyError and StopIteration are lookups, not bugs).
      BUG_CLASSES = [
        NameError, TypeError, ZeroDivisionError, FloatDomainError, FrozenError, NotImplementedError,
        SystemStackError, NoMatchingPatternError, LocalJumpError, ThreadError, IndexError, RangeError,
      ].freeze

      # Never treated as bugs (subclasses of BUG_CLASSES).
      NOT_BUGS = [KeyError, StopIteration].freeze

      # Backtrace frames of the console itself, left out of traces.
      CONSOLE_FRAMES = %r{/pry-[^/]*/lib/pry|/bin/sound\.rb:|<internal:|/reline|/irb}

      LIB_DIR = File.expand_path('..', __dir__)

      module_function

      # The error's message without "Did you mean?" blocks and Ruby's
      # "for module MB::Sound" receiver (the console's own), plus its
      # suggestions: [message, [suggestion, ...]].
      def message_and_suggestions(e)
        message = e.message.to_s
        suggestions = []
        message = message.gsub(/\n\s*Did you mean\?\s+(.*?)(?=\n\S|\z)/m) {
          suggestions.concat($1.split(/\s*\n\s*/).map(&:strip).reject(&:empty?))
          ''
        }
        if e.respond_to?(:corrections)
          begin
            suggestions.concat(Array(e.corrections).map(&:to_s))
          rescue StandardError
            nil
          end
        end
        console = e.is_a?(NameError) && (e.receiver.equal?(MB::Sound) rescue false)
        if console && !e.is_a?(NoMethodError) && (hint = session_name_hint(e.name))
          suggestions.unshift(hint)
        elsif e.is_a?(NoMethodError) && (e.receiver.is_a?(Symbol) rescue false) && MB::Sound.respond_to?(e.name) && !Symbol.method_defined?(e.name)
          # (ux-notes-1: the maintainer's `swap :growl. seq(...)`, a period
          # for a comma after a name)
          suggestions.replace(["#{e.receiver.inspect}, #{e.name}(...) (a comma after #{e.receiver.inspect}, not a period)"])
        elsif console && e.is_a?(NoMethodError) && (hint = GUESSES[e.name])
          # (Ruby's spelling suggestions for these, write and collect, lead
          # nowhere)
          suggestions.replace([hint.call(*e.args.first(1))])
        end
        message = message.sub(/ for module MB::Sound\z/, '').sub(/ for module MB::Sound(?=\n)/, '')
        [message.rstrip, suggestions.uniq]
      end

      # Console guesses with no method of that name, and what they meant
      # (ux-notes-1: the maintainer's `wire :bowl, clip` and `connect
      # :bowl, clip`, after swap refused a stream): name => Proc of the
      # first argument giving the suggestion.
      CLIP_ON_TRACK = ->(name = :bass, *) {
        n = name.is_a?(Symbol) ? name.inspect : ':bass'
        "swap #{n}, clip (a clip on #{n}'s instrument, at its next launch point; bg #{n}, clip starts a stopped track)"
      }
      GUESSES = { wire: CLIP_ON_TRACK, connect: CLIP_ON_TRACK, attach: CLIP_ON_TRACK }.freeze

      # For a bare word the console doesn't know that names something in
      # the current Session (a track, scene, or knob), the Symbol to write
      # (`design bowl` for `design :bowl`; ux-notes-1), else nil.
      def session_name_hint(name)
        return nil unless name.is_a?(Symbol)
        s = Session.existing or return nil
        arr = s.arrangement
        kind = if arr.tracks.key?(name) then 'track'
               elsif arr.scenes.key?(name) then 'scene'
               elsif s.knobs.key?(name) then 'knob'
               end
        kind && "#{name.inspect}, the #{kind}'s name"
      rescue StandardError
        nil
      end

      # "Class: message (did you mean x?)", the message's later lines kept.
      def summary(e)
        message, suggestions = message_and_suggestions(e)
        text = "#{e.class.name}: #{message}"
        text << " (did you mean #{suggestions.first(3).join(', ')}?)" unless suggestions.empty?
        text
      end

      # True if +e+ prints as #summary alone (see the module description).
      def short?(e)
        return true if NOT_BUGS.any? { |c| e.is_a?(c) }
        return true unless BUG_CLASSES.any? { |c| e.is_a?(c) }

        !raised_inside?(e)
      end

      # True if +e+'s first backtrace frame is in mb-sound's lib/ or a gem
      # (not the user's code at the prompt or in a script).
      def raised_inside?(e)
        path = e.backtrace&.first.to_s.sub(/:\d+:in .*\z/, '')
        return false if path.empty?

        path.start_with?(LIB_DIR) || path.include?('/gems/') || path.include?('/bundler/') || path.start_with?('<internal:')
      end

      # The console's text for +e+: #summary for short errors, else a
      # backtrace without the console's frames; colored if +color+.
      def console(e, color: ColorPolicy.color?($stdout))
        text = if short?(e)
                 line = summary(e)
                 color ? colorize(line) : line
               else
                 trace = MB::U.color_trace(e, exclude: CONSOLE_FRAMES)
                 _, suggestions = message_and_suggestions(e)
                 trace = "#{trace}\n\e[33mDid you mean #{suggestions.first(3).join(', ')}?\e[0m" unless suggestions.empty?
                 color ? trace : ColorPolicy.strip(trace)
               end
        text
      end

      # Ruby's own argument errors (arity and keywords), which
      # #argument_help rewrites.
      ARGUMENT_ERROR = /\A(?:wrong number of arguments \(.+\)|unknown keywords?: .+|missing keywords?: .+)\z/

      # For Ruby's arity or keyword ArgumentError +e+ raised by the method
      # +name+ of +receiver+ itself (not by something it called), a new
      # error naming the method, with did_you_mean suggestions for unknown
      # keywords from its keywords (or the list of them) and, for arity and
      # missing keywords, its signature; else nil.  The DSL's recorders
      # call it (GraphNode::Recipe.record), so every recorded DSL method
      # suggests (ux-fix-1: `lp4(800, resonanse: 0.3)`) and says what it
      # takes (notes-fix-1: `lp4` alone).
      #
      # +method+ (an UnboundMethod or Method) skips finding the raising
      # method from the backtrace (MIDI::Stream's transforms, whose errors
      # come from the transform classes they build); +keys+ adds keywords
      # it takes through **options; +hints+ maps other guesses at a
      # keyword to the keyword (`echo(transpose: 5)`: pitch:); +example+
      # is a working call, added after "e.g.".
      def argument_help(e, receiver, name, method: nil, keys: nil, hints: nil, example: nil)
        return nil unless e.message.match?(ARGUMENT_ERROR)
        meth = method || raising_method(e, receiver, name) or return nil

        keys = (keywords_of(meth) + keys.to_a).uniq
        text = "#{name}: #{e.message}"
        found = []
        if (m = e.message.match(/\Aunknown keywords?: (.+)\z/))
          return nil if keys.empty? && example.nil?
          unknown = m[1].scan(/:(\w+[?!]?)/).flatten
          found = unknown.flat_map { |u|
            hint = hints&.[](u.to_sym)
            hint ? [hint.to_s] : DidYouMean::SpellChecker.new(dictionary: keys.map(&:to_s)).correct(u)
          }.uniq
          text << " (#{name} takes #{keys.map { |k| "#{k}:" }.join(', ')})" if found.empty? && !keys.empty?
        else
          text << "; #{name}(#{signature(meth)})"
        end
        text << "; e.g. #{example}" if example
        text << "\nDid you mean?  #{found.map { |k| "#{k}:" }.join("\n                ")}" unless found.empty?
        error = ArgumentError.new(text)
        error.set_backtrace(e.backtrace_locations || e.backtrace)
        error
      rescue StandardError
        nil
      end

      # The method of +receiver+ named +name+ (or a super method) that
      # raised +e+ itself, or nil.
      def raising_method(e, receiver, name)
        loc = e.backtrace_locations&.first or return nil
        chain = []
        meth = receiver.method(name)
        (chain << meth; meth = meth.super_method) while meth
        # (Ruby reports arity and keyword errors at the def line; wrappers
        # defined in the same file may come first)
        meth = chain.find { |m| m.source_location == [loc.path, loc.lineno] } || chain.find { |m| m.source_location&.first == loc.path }
        return nil if meth.nil? || meth.name != loc.base_label.to_sym && meth.original_name != loc.base_label.to_sym

        meth
      end

      # The keyword names +meth+ takes.
      def keywords_of(meth)
        meth.parameters.filter_map { |type, key| key if type == :key || type == :keyreq }
      end

      # The parameter list of +meth+ as written in its source (defaults
      # included), or built from its parameters.
      def signature(meth)
        file, line = meth.source_location
        if file && File.file?(file)
          require 'prism'
          node = find_def(Prism.parse_file(file).value, meth.original_name, line)
          return node.parameters&.slice.to_s.gsub(/\s*\n\s*/, ' ') if node
        end

        meth.parameters.map { |type, n|
          case type
          when :req then n.to_s
          when :opt then "#{n} = ..."
          when :rest then "*#{n}"
          when :keyreq then "#{n}:"
          when :key then "#{n}: ..."
          when :keyrest then "**#{n}"
          when :block then "&#{n}"
          end
        }.compact.join(', ')
      end

      # The `def` of +name+ starting at +line+ under Prism +node+, or nil.
      def find_def(node, name, line)
        return node if node.is_a?(Prism::DefNode) && node.name == name && node.location.start_line == line

        node.compact_child_nodes.each do |c|
          next if c.location.start_line > line || c.location.end_line < line
          found = find_def(c, name, line) and return found
        end
        nil
      end

      # Colors a #summary: the class name red, suggestions yellow.
      def colorize(text)
        text
          .sub(/\A([\w:]+):/) { "\e[1;31m#{$1}\e[0m:" }
          .sub(/ \(did you mean (.*)\?\)$/) { " (did you mean \e[33m#{$1}\e[0m?)" }
      end
    end
  end
end
