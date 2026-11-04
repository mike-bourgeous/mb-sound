module MB
  module Sound
    module GraphIO
      # DSL settings that take only numbers while a graph builds, with why
      # (fit-patch-2, 2026-11-04).  Every other number a graph document
      # holds may be a param instead (the document's `param` lines, a
      # track's knobs): settings read once while building take a param or
      # knob as its number (GraphNode.build_setting), settings that move
      # take nodes.  FitPatch leaves a literal at one of these settings a
      # number (listed in Patch#skipped with the reason), so a fit always
      # loads.
      #
      # The guard (spec/lib/mb/sound/graph_io/number_only_spec.rb) writes
      # every graph sweep factory's document with each of its Float
      # literals as a param: a literal whose param doesn't load and play
      # must sit at a setting listed here, and every entry here must still
      # refuse a param somewhere in the sweep (or its probes), so the list
      # stays exact.  Integer literals (counts, seeds, notes, controller
      # numbers, voices) are structure and stay out of the sweep.
      #
      # A setting is [call, argument]: the call's method name (`tween`),
      # or `Const.name` for a call on a constant (`Filter::Biquad.new`);
      # the argument a keyword (Symbol), a position (Integer), :self for
      # the call's receiver, or :* for any of its arguments.  A literal's
      # setting is the innermost call it is an argument (or receiver) of.
      module NumberOnly
        # { call => { argument => reason } }
        SETTINGS = {
          'tween' => { 0 => 'keyframe values are data (a Tween steps through numbers or Pitches); tween a knob instead' },
          'constant' => { self: 'the number of a constant node: a param is already one, so write the param' },
          'quantize' => { 0 => 'a node increment plays the plain live bitcrusher (aquantize: no antialiasing, not in one-sample ' \
                               'feedback loops); a number keeps the antialiased shaper' },
          'events' => { :* => "a clip's events are data (starts, lengths, velocities, lane values): numbers, not nodes" },
          'lowpass' => { quality: 'a Pitch filter object (3000.hz.lowpass) computes its coefficients from numbers; use ' \
                                  'filter(:lowpass, cutoff:, quality:) for params' },
          'highpass' => { quality: 'a Pitch filter object (3000.hz.highpass) computes its coefficients from numbers; use ' \
                                   'filter(:highpass, cutoff:, quality:) for params' },
        }.freeze

        # [pattern of calls, argument, reason]: families of calls.
        PATTERNS = [
          [/\AFilter::\w+\.new\z/, :*, 'filter objects (Filter::Biquad.new, Cookbook.new, ...) compute coefficients from numbers; use ' \
                                       'the filter DSL (filter(:peak, cutoff:, quality:, gain:)) for params'],
        ].freeze

        module_function

        # Why +setting+ ([call, argument], see the module) takes only
        # numbers, or nil.
        def reason(setting)
          return nil if setting.nil?
          call, arg = setting
          row = SETTINGS[call]
          found = row && (row[arg] || row[:*])
          return found if found
          PATTERNS.each { |re, a, why| return why if re.match?(call) && (a == :* || a == arg) }
          nil
        end

        # Every entry as [call (a String or Regexp), argument, reason].
        def entries
          SETTINGS.flat_map { |call, row| row.map { |arg, why| [call, arg, why] } } + PATTERNS
        end
      end
    end
  end
end
