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
        message = message.sub(/ for module MB::Sound\z/, '').sub(/ for module MB::Sound(?=\n)/, '')
        [message.rstrip, suggestions.uniq]
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

      # For an "unknown keyword" ArgumentError +e+ raised by the method
      # +name+ of +receiver+ itself (not by something it called), a new
      # error naming the method with did_you_mean suggestions from its
      # keywords (or the list of them); else nil.  The DSL's recorders call
      # it (GraphNode::Recipe.record), so every recorded DSL method suggests
      # (ux-fix-1: `lp4(800, resonanse: 0.3)`).
      def unknown_keyword(e, receiver, name)
        m = e.message.match(/\Aunknown keywords?: (.+)\z/) or return nil
        loc = e.backtrace_locations&.first or return nil
        meth = receiver.method(name)
        meth = meth.super_method while meth && meth.source_location&.first != loc.path
        return nil if meth.nil? || meth.name != loc.base_label.to_sym && meth.original_name != loc.base_label.to_sym

        keys = meth.parameters.filter_map { |type, key| key if type == :key || type == :keyreq }
        return nil if keys.empty?

        unknown = m[1].scan(/:(\w+[?!]?)/).flatten
        found = unknown.flat_map { |u| DidYouMean::SpellChecker.new(dictionary: keys.map(&:to_s)).correct(u) }.uniq
        text = "#{name}: #{e.message}"
        text << if found.empty?
                  " (#{name} takes #{keys.map { |k| "#{k}:" }.join(', ')})"
                else
                  "\nDid you mean?  #{found.map { |k| "#{k}:" }.join("\n                ")}"
                end
        error = ArgumentError.new(text)
        error.set_backtrace(e.backtrace_locations || e.backtrace)
        error
      rescue StandardError
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
