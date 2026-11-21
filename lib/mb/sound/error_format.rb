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
        elsif e.is_a?(NoMethodError) && (hint = node_guess(e) || entry_guess(e) || value_guess(e))
          suggestions.replace([hint])
        end
        message = message.sub(/ for module MB::Sound\z/, '').sub(/ for module MB::Sound(?=\n)/, '')
        [message.rstrip, suggestions.uniq]
      end

      # Console guesses with no method of that name, and what they meant
      # (ux-notes-1: the maintainer's `wire :bowl, clip` and `connect
      # :bowl, clip`, after swap refused a stream; `wire`/`connect` are
      # commands since wire-1, refusing a clip with the same hint):
      # name => Proc of the first argument giving the suggestion.
      CLIP_ON_TRACK = ->(name = :bass, *) {
        n = name.is_a?(Symbol) ? name.inspect : ':bass'
        "swap #{n}, clip (a clip on #{n}'s instrument, at its next launch point; bg #{n}, clip starts a stopped track) " \
          "or wire #{n}, stream (a MIDI stream into #{n}'s instrument)"
      }
      # (sd-ux-fixes-1, the review's #19: `note :lead, "..."` to keep a
      # note with a track's sound; no command by that name, by choice)
      NOTE_ON_TRACK = ->(name = :lead, *) {
        n = name.is_a?(Symbol) ? name.inspect : ':lead'
        "meta #{n}, notes: '...' (kept with #{n}, saved with the set), about: '...' when you save a graph, " \
          "or ui.note '...' (a note about what you hear, with the screen)"
      }
      GUESSES = { attach: CLIP_ON_TRACK, note: NOTE_ON_TRACK }.freeze

      # Method names people reach for on graph nodes, and what they meant
      # (feedback-api-guesses: the omnibus19 name test's runners-up for
      # derivative and integral; Kez's `transpose` on a tone after `.fm`,
      # where Ruby suggested "transients"): name => suggestion, or a Proc of
      # the receiver giving one (nil to keep Ruby's).
      SLOPE = 'derivative (the slope of a signal; aliases slope, differentiate)'
      SUM = 'integral (the running sum of a signal; aliases integrate, accumulate)'
      NODE_GUESSES = {
        delta: SLOPE, diff: SLOPE, difference: SLOPE, deriv: SLOPE, ddt: SLOPE,
        cumsum: SUM, running_sum: SUM, accum: SUM, sum: SUM, integ: SUM,
        # (ux-friction-1: the maintainer's `fx :pluck, ->{ it.echo }`)
        echo: 'delay(0.375, feedback: 0.4) (an echo; also tape_echo, ping_pong, dual_delay, or the library\'s L.fx.dub_echo)',
        # (ux-friction-1 round 2: the maintainer's `2.bars.lfo.ramp.exp`
        # for a cutoff sweep, his note "exponential lfo?", then
        # `.unipolar` and `.freerun` on the same LFO)
        exp: EXP_SWEEP = 'at(D3.number..B6.number).freq (an LFO swept in notes, even steps in pitch, as a filter sweep wants) ' \
                         'or 150 * 2 ** lfo.at(0..Math.log2(2000 / 150.0)) (150 to 2000 Hz, exponential)',
        exponential: EXP_SWEEP, expo: EXP_SWEEP,
        unipolar: UNIPOLAR = 'at(150..2000) (it maps the whole -1..1 swing onto 150..2000, so no unipolar step is needed; .at(0..1) for 0 to 1)',
        bipolar: UNIPOLAR,
        freerun: FREERUN = 'freewheel (a bar-synced LFO running free of the timeline: 2.bars.lfo.freewheel; ' \
                           'a Hz LFO like 0.2.hz.lfo already runs free, and free only stops synth voices key-syncing a tone)',
        free_run: FREERUN, freerunning: FREERUN, free_running: FREERUN,
        transpose: ->(node) {
          next nil unless node.is_a?(Tone)

          'v.hz.transpose(7).fm(...) (transpose the pitch first: .fm, .saw, and the like make it a Tone, ' \
            'which has no transpose) or v.hz.vibrato(5.5, depth: 30.cents) (vibrato that stays a pitch)'
        },
      }.freeze

      # The NODE_GUESSES suggestion for NoMethodError +e+ on a graph node,
      # or nil.
      def node_guess(e)
        node = e.receiver
        return nil unless node.is_a?(GraphNode) || node.is_a?(GraphNode::Channels)

        hint = NODE_GUESSES[e.name]
        hint.respond_to?(:call) ? hint.call(node) : hint
      rescue StandardError
        nil
      end

      # Operators people reach for to chain library effects (ux-friction-1:
      # the maintainer's `L.fx.cabinet | L.fx.asymmetric`, `&`, `+`), and
      # the list that chains them.
      ENTRY_CHAIN = %i[| & + >> << chain pipe compose].freeze

      # The ENTRY_CHAIN suggestion for NoMethodError +e+ on a library
      # Entry, or nil.
      def entry_guess(e)
        entry = e.receiver
        return nil unless entry.is_a?(Library::Entry) && ENTRY_CHAIN.include?(e.name)

        other = e.args.first
        b = other.is_a?(Library::Entry) ? other.head_path : 'L.fx.hall'
        Library::Entry.chain_hint(entry.head_path, b)
      rescue StandardError
        nil
      end

      # Mode names and wave shapes tried as methods on values (ux-friction-1
      # round 2: the maintainer's `scale.phrygian`, `A2.minor`, and
      # `1.beat.ramp.lfo`), and what they meant, or nil.
      def value_guess(e)
        r = e.receiver
        name = e.name
        if r.is_a?(Scale) && Scale.names.include?(name)
          "scale(#{name.inspect}) (a mode by name; scale(#{name.inspect}, :a) on A)"
        elsif r.is_a?(Note) && Scale.names.include?(name)
          "scale(#{name.inspect}, #{r.name}) (the mode first, then the root)"
        elsif r.is_a?(Sequence::Duration) && Tone::WAVE_TYPES.include?(name)
          d = RubyValue.to_ruby(r)
          "#{d}.lfo.#{name} (the shape comes after .lfo; #{d}.hz.#{name} is a tone at that rate)"
        elsif (r.is_a?(UI::Facade) || r.is_a?(UI::Pending)) && %i[warn warning warnings].include?(name)
          # (his `ui.warn`, looking for where warnings show with a screen up)
          'ui.messages (the messages pane, NAV m: warnings from players and threads; the console\'s own commands warn in the REPL) ' \
            'or ui.message 1 (the newest in full)'
        end
      rescue StandardError
        nil
      end

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
        # A constant typed at the prompt that isn't a note name reaches
        # MB::Sound.const_missing's super inside lib/ (ux-friction-1 round
        # 2: the maintainer's `motifs(III, ...)` printed a backtrace)
        return true if e.instance_of?(NameError) && e.backtrace_locations&.first&.label.to_s.end_with?('MB::Sound.const_missing')
        # A proxy's method_missing passing an unknown name to super (`ui.warn`,
        # `ui.foo`: UI::Facade) raises from inside lib/ for a typo at the
        # prompt (ux-friction-1 round 2)
        return true if e.is_a?(NoMethodError) && e.backtrace_locations&.first&.label.to_s.end_with?('#method_missing')

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

      # Keywords people guess for recorded DSL methods, and the keyword
      # they meant (ux-friction-1 round 2: the maintainer's
      # `unison(5, pan: 0..1)` and `motifs(..., length: 1.n8)`):
      # method name => { guess => keyword }.
      KEYWORD_GUESSES = {
        unison: { pan: :spread, width: :spread, stereo: :spread, amount: :detune, cents: :detune },
        motifs: { length: :legato, gate: :legato, note_length: :legato, steps: :step, division: :step, scale: :range },
      }.freeze

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
        hints ||= KEYWORD_GUESSES[name.to_sym]
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
