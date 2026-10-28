require 'did_you_mean'

require_relative 'form/builder'
require_relative 'form/state'
require_relative 'form/playback'

module MB
  module Sound
    # A song form: named sections (each launching a scene of the same name
    # for some bars) in a play order, with repeats, labels, gotos and picks
    # that choose where the flow goes, fills at the ends of sections, and
    # phrase fills every few bars.  Built with a block (see Form::Builder),
    # played by an Arrangement (see Form::Playback), and printed back as the
    # same Ruby block by #to_ruby (so `take.form` can show what was played
    # as code to paste).  See design/notes/arrangement.md.
    #
    #     flow do
    #       intro  8
    #       label  :top                   # a target for goto (takes no time)
    #       verse  8
    #       pick   chorus: 3, drop: 1     # plays one of them, then carries on
    #       verse
    #       drop   16, fill: [:riser, 4]
    #       goto   :top, times: 2         # back to :top twice more, then on
    #       outro  8
    #     end
    #
    #     flow do                         # generative: never ends
    #       label :a; groove 8; pick hook: 2, stab: 1
    #       label :b; breakdown 8
    #       goto a: 3, b: 1               # a weighted random target
    #     end
    #
    # What follows a section is decided by the flow, never by the section:
    # a section plays the same way wherever it appears.
    #
    # Lengths are Durations (8.bars, 6.beats) or plain numbers of bars
    # (counted in the meter where the section starts).  Trap: `verse 8.bars
    # * 2` is one 16-bar verse; write `verse 8.bars, times: 2` (or call it
    # twice) for two plays.
    class Form
      # When a section's fill plays: at the end of every pass (:pass, the
      # default) or only when the form leaves the section (:leave).
      FILL_ON = [:pass, :leave].freeze

      # Names the flow builder uses for its own steps (not section names).
      STEP_NAMES = [:repeat, :fill, :label, :goto, :pick].freeze

      # The goto target that carries on to the next step (`goto top: 3,
      # next: 1`); not a label name.
      NEXT = :next

      # The section options (see Section).  Knob names are options too
      # (knob values turned as each pass starts).
      SECTION_OPTIONS = [:times, :fill, :scene, :fade].freeze

      # Splits section +options+ into the SECTION_OPTIONS and knob values
      # (keys that are knobs of the current Session).  Raises for anything
      # else, with suggestions.
      def self.section_options(name, options)
        unknown = options.keys - SECTION_OPTIONS
        # (knob names, and names standing for a control: a trigger track's
        # level, `drop 8, pump: 0`; Session::Knobs#control_name)
        knob_names = (Session.current.control_names + Arrangement::KEY_VALUES + Arrangement::TEMPO_VALUES).uniq
        knobs = options.slice(*(unknown & knob_names))
        unknown -= knob_names
        unless unknown.empty?
          hint = suggest(unknown.first, SECTION_OPTIONS + knob_names)
          raise ArgumentError, "#{name}: unknown options #{unknown.map(&:inspect).join(', ')} (use #{SECTION_OPTIONS.map { |o| "#{o}:" }.join(', ')}, or knob names)#{hint}"
        end
        [options.slice(*SECTION_OPTIONS), knobs]
      end

      # A section: its +name+, +length+ (a Duration, or a number of bars),
      # how many passes it plays (+times+), its +fill+ (nil, or a Fill),
      # the scene it launches (+scene+: nil for the scene named like the
      # section, false for none), a launch +fade+ in bars (nil for the
      # scene's own), and +knobs+ to turn as each pass starts (a Hash from
      # knob name to a value, as in scenes: `drop 8, cut: 8000`).
      Section = Data.define(:name, :length, :times, :fill, :scene, :fade, :knobs) do
        def initialize(name:, length:, times: 1, fill: nil, scene: nil, fade: nil, knobs: {})
          raise ArgumentError, "Section names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          Form.check_length(name, length)
          raise ArgumentError, "#{name}: times: must be a positive Integer (got #{times.inspect})" unless times.is_a?(Integer) && times > 0
          raise ArgumentError, "#{name}: scene: must be a Symbol, false, or nil (got #{scene.inspect})" unless scene.nil? || scene == false || scene.is_a?(Symbol)
          raise ArgumentError, "#{name}: knobs must be a Hash (got #{knobs.inspect})" unless knobs.is_a?(Hash)
          super(name: name, length: length, times: times, fill: fill, scene: scene, fade: fade, knobs: knobs.dup.freeze)
        end

        # The keyword options that rebuild this section (for #to_ruby).
        def options
          opts = {}
          opts[:times] = times if times != 1
          opts[:fill] = fill.to_option if fill
          opts[:scene] = scene unless scene.nil?
          opts[:fade] = fade unless fade.nil?
          opts.merge(knobs)
        end
      end

      # A section's fill: the fill names to play in the section's last
      # +length+ (alternating per pass when there are several), and whether
      # it plays on every pass or only when leaving (+on+: :pass or :leave).
      # A fill whose name is a scene launches that scene (usually a partial
      # scene, e.g. a riser); clips with fill marks (see Sequence::Clip#fill)
      # play their fill notes in the fill's bars either way.
      Fill = Data.define(:names, :length, :on) do
        # Builds a Fill from a section's +fill:+ option: a name, an Array of
        # names (alternating per pass), optionally ending with a length
        # (`[:riser, 4.bars]`, default 1 bar), or a Hash with :names (or
        # :name), :length, and :on.
        def self.from(value, section: nil)
          case value
          when nil, false
            nil
          when Symbol
            new(names: [value].freeze, length: 1, on: :pass)
          when Array
            names = value.dup
            length = Form.length?(names.last) ? names.pop : 1
            raise ArgumentError, "#{section}: fill: names must be Symbols (got #{value.inspect})" if names.empty? || !names.all?(Symbol)
            new(names: names.freeze, length: length, on: :pass)
          when Hash
            names = Array(value[:names] || value[:name])
            raise ArgumentError, "#{section}: fill: needs :names (got #{value.inspect})" if names.empty? || !names.all?(Symbol)
            new(names: names.freeze, length: value.fetch(:length, 1), on: value.fetch(:on, :pass))
          else
            raise ArgumentError, "#{section}: fill: must be a name, an Array of names (and a length), or a Hash (got #{value.inspect})"
          end
        end

        def initialize(names:, length:, on:)
          Form.check_length(:fill, length)
          raise ArgumentError, "fill on: must be #{FILL_ON.map(&:inspect).join(' or ')} (got #{on.inspect})" unless FILL_ON.include?(on)
          super
        end

        # The fill name for pass +pass+ (counting from 1).
        def name_for(pass)
          names[(pass - 1) % names.length]
        end

        # The shortest +fill:+ option that builds this fill.
        def to_option
          if on == :pass && length == 1 && names.length == 1
            names.first
          elsif on == :pass
            length == 1 ? names : [*names, length]
          else
            h = { names: names }
            h[:length] = length unless length == 1
            h[:on] = on
            h
          end
        end
      end

      # A phrase fill: fill +name+ plays for +length+ at the end of every
      # +every+ bars from each section's start (`fill :big, every: 16`).
      # When several land on the same bar, the one with the longest period
      # wins, unless +layer+ is true (it then plays alongside).  A section's
      # own fill wins over phrase fills.
      PhraseFill = Data.define(:name, :every, :length, :layer) do
        def initialize(name:, every:, length: 1, layer: false)
          raise ArgumentError, "Phrase fill names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "#{name}: every: must be a positive number of bars (got #{every.inspect})" unless every.is_a?(Numeric) && every > 0
          Form.check_length(name, length)
          super
        end

        def to_ruby
          opts = ["every: #{Form.ruby_value(every)}"]
          opts << "length: #{Form.ruby_value(length)}" unless length == 1
          opts << 'layer: true' if layer
          "fill #{name.inspect}, #{opts.join(', ')}"
        end
      end

      # Entries in the play order:
      # - Play: a section played (+name+, with a per-step +times+ or nil for
      #   the section's).
      # - Repeat: a group of entries (+steps+) played +count+ times.
      # - Label: a named position (+name+) that gotos jump to; takes no time.
      # - Goto: jumps to a label (+target+: a label, a Hash from labels to
      #   weights for a random one, where :next means carry on to the next
      #   step, or a Proc given a Form::State that returns a label, or nil
      #   or :next to carry on), every time it is reached, or
      #   +times+ times and then falls through once (its count then starts
      #   over, so a goto inside a bigger loop repeats its own loop on every
      #   pass of the bigger one).
      # - Pick: plays one of its +options+ (Options: a +weight+ and the
      #   +steps+ to play, which may be empty), then carries on after it.
      Play = Data.define(:name, :times)
      Repeat = Data.define(:count, :steps)
      Label = Data.define(:name)
      Goto = Data.define(:target, :times)
      Pick = Data.define(:options)
      Option = Data.define(:weight, :steps)

      # Raises unless +length+ is a section length (a positive Duration or
      # number of bars).
      def self.check_length(name, length)
        return if length?(length) && length.to_r > 0
        raise ArgumentError, "#{name}: lengths are Durations (8.bars, 6.beats) or numbers of bars (got #{length.inspect})"
      end

      # True if +value+ looks like a length (a Duration or a Numeric).
      def self.length?(value)
        value.is_a?(Sequence::Duration) || (value.is_a?(Numeric) && !value.is_a?(Complex))
      end

      # Raises unless +weights+ is a Hash of name => weight pairs (for goto
      # and pick; +what+ names the step in messages).
      def self.check_weights(what, weights)
        bad = weights.reject { |k, w| k.is_a?(Symbol) && w.is_a?(Numeric) && w >= 0 }
        raise ArgumentError, "#{what}: weights must be name => number pairs (got #{bad.inspect})" unless bad.empty?
        raise ArgumentError, "#{what}: weights can't all be zero" unless weights.values.sum > 0
      end

      # Raises unless +target+ is a goto target (see Goto).
      def self.check_goto(target, times)
        case target
        when Symbol, Proc
          nil
        when Hash
          check_weights('goto', target)
        else
          raise ArgumentError, "goto needs a label (goto :top), a Hash of weighted labels (goto a: 3, b: 1), or a Proc returning a label (got #{target.inspect})"
        end
        raise ArgumentError, "goto times: must be a positive Integer or nil for always (got #{times.inspect})" unless times.nil? || (times.is_a?(Integer) && times > 0)
      end

      # A "Did you mean?" hint for +name+ among +names+ ('' if none), as
      # Symbols (or as bare names, for methods, if +symbols+ is false).
      def self.suggest(name, names, symbols: true)
        found = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s)
        found = found.map { |n| n.to_sym.inspect } if symbols
        found.empty? ? '' : "\nDid you mean?  #{found.join("\n                ")}"
      end

      # Builds a Form from a block (see Builder).  +sections+ are sections
      # declared outside the block (e.g. with Arrangement#section), which
      # bare calls in the block can play.
      def self.build(sections: {}, &block)
        Builder.build(sections: sections, &block)
      end

      # Ruby code for a length or option value (see #to_ruby).
      def self.ruby_value(value)
        case value
        when Sequence::Duration
          label = value.instance_variable_get(:@label).to_s
          if (m = label.match(/\A(-?[\d.\/]+) (bar|bars|beat|beats)\z/))
            n = m[1]
            n = "(#{n}r)" if n.include?('/')
            "#{n}.#{m[2]}"
          else
            "MB::Sound::Sequence::Duration.new(#{ruby_value(value.to_r)})"
          end
        when Rational
          value.denominator == 1 ? value.numerator.to_s : "#{value.numerator}/#{value.denominator}r"
        when Hash
          value.empty? ? '{}' : "{ #{value.map { |k, v| "#{k}: #{ruby_value(v)}" }.join(', ')} }"
        when Array
          "[#{value.map { |v| ruby_value(v) }.join(', ')}]"
        when Proc
          '->(f) { nil }'
        else
          value.inspect
        end
      end

      # The sections by name (a frozen Hash).
      attr_reader :sections

      # The play order: Play, Repeat, Label, Goto, and Pick entries (a
      # frozen Array).
      attr_reader :order

      # Phrase fills (PhraseFill, a frozen Array).
      attr_reader :phrase_fills

      # The play order compiled for Playback: a frozen Array of
      # instructions, each a frozen Array: [:play, name, times], [:label,
      # name], [:goto, target, times], [:pick, [[weight, index], ...],
      # end_index], or [:jump, index].  Repeats are unrolled; each pick
      # option ends with a jump past the pick.
      attr_reader :program

      # Label names to their instruction index in #program.
      attr_reader :labels

      def initialize(sections:, order:, phrase_fills: [])
        @sections = sections.dup.freeze
        @order = order.dup.freeze
        @phrase_fills = phrase_fills.dup.freeze
        check_order(@order)
        @program = compile(@order, []).freeze
        @labels = check_program.freeze
        freeze
      end

      # The order straight through, as an Array of [section name, times]:
      # repeats unrolled, gotos not taken, the first option of each pick.
      def steps
        straight.map { |i| @program[i].drop(1) }
      end

      # The total length in bars of #steps, counting Durations at
      # +bar_length+ (whole notes per bar).
      def bars(bar_length: 1r)
        steps.sum { |name, times|
          len = @sections[name].length
          (len.is_a?(Sequence::Duration) ? len.to_r / bar_length : len.to_r) * times
        }
      end

      def ==(other)
        other.is_a?(Form) && to_ruby == other.to_ruby
      end
      alias eql? ==

      def hash
        to_ruby.hash
      end

      # Ruby code that builds this form again: a `flow do ... end` block
      # (Procs in gotos can't be printed and become placeholders with a
      # comment).
      def to_ruby
        declared = {}
        lines = ['flow do']
        @phrase_fills.each { |f| lines << "  #{f.to_ruby}" }
        emit(@order, declared, lines, '  ')
        lines << 'end'
        lines.join("\n")
      end
      alias to_s to_ruby

      def inspect
        "#<MB::Sound::Form\n#{to_ruby}>"
      end

      def pretty_print(q)
        q.text(inspect)
      end

      private

      # Checks that order entries are valid and plays and picks name
      # sections of the form.
      def check_order(entries)
        entries.each do |e|
          case e
          when Play
            check_section(e.name)
          when Repeat
            check_order(e.steps)
          when Pick
            raise ArgumentError, 'pick needs at least one option' if e.options.empty?
            Form.check_weights('pick', e.options.each_with_index.to_h { |o, i| [:"option#{i + 1}", o.weight] })
            e.options.each { |o| check_order(o.steps) }
          when Label
            raise ArgumentError, "Label names must be Symbols (got #{e.name.inspect})" unless e.name.is_a?(Symbol)
            raise ArgumentError, "label #{e.name.inspect} is also a section name; give the label its own name (e.g. :#{e.name}_top)" if @sections.key?(e.name)
            raise ArgumentError, 'label :next is reserved (`goto top: 3, next: 1` means carry on to the next step); give the label another name (e.g. :onward)' if e.name == NEXT
          when Goto
            Form.check_goto(e.target, e.times)
          else
            raise ArgumentError, "Form order entries are Play, Repeat, Label, Goto, or Pick (got #{e.inspect})"
          end
        end
      end

      def check_section(name)
        return if @sections.key?(name)
        hint = Form.suggest(name, @sections.keys)
        hint = "\n(declare it with its length somewhere in the flow, e.g. `#{name} 8`, or in a pick block: `p.option(1) { #{name} 8 }`)" if hint.empty?
        raise ArgumentError, "No section #{name.inspect} in the form#{hint}"
      end

      # Checks labels (unique) and goto targets (labels of the form, and
      # loops that play something).  Returns label name => index.
      def check_program
        labels = {}
        @program.each_with_index do |ins, i|
          next unless ins[0] == :label
          raise ArgumentError, "label #{ins[1].inspect} appears more than once (a label inside repeat repeats too); labels must be unique" if labels.key?(ins[1])
          labels[ins[1]] = i
        end

        @program.each_with_index do |ins, i|
          next unless ins[0] == :goto
          targets = case ins[1]
                    when Symbol then [ins[1]]
                    when Hash then ins[1].keys
                    else []
                    end
          targets.each do |t|
            next if t == NEXT
            unless labels.key?(t)
              hint = @sections.key?(t) ? "\n(:#{t} is a section; put `label :#{t}_top` (any new name) before it and goto that)" : Form.suggest(t, labels.keys)
              raise ArgumentError, "goto #{t.inspect}: no label #{t.inspect} in the form#{hint}"
            end
            li = labels[t]
            if li <= i && @program[li...i].none? { |x| x[0] == :play }
              raise ArgumentError, "goto #{t.inspect} would loop forever without playing a section"
            end
          end
        end

        labels
      end

      # Appends the instructions for +entries+ to +out+.  Returns +out+.
      def compile(entries, out)
        entries.each do |e|
          case e
          when Play
            out << [:play, e.name, e.times || @sections[e.name].times].freeze
          when Repeat
            e.count.times { compile(e.steps, out) }
          when Label
            out << [:label, e.name].freeze
          when Goto
            out << [:goto, e.target, e.times].freeze
          when Pick
            at = out.length
            out << nil
            starts = []
            jumps = []
            e.options.each do |o|
              starts << [o.weight, out.length].freeze
              compile(o.steps, out)
              jumps << out.length
              out << nil
            end
            finish = out.length
            out[at] = [:pick, starts.freeze, finish].freeze
            jumps.each { |j| out[j] = [:jump, finish].freeze }
          end
        end
        out
      end

      # The indices of the plays straight through (see #steps).
      def straight
        list = []
        i = 0
        while (ins = @program[i])
          case ins[0]
          when :play then list << i
          when :pick then i = ins[1].first[1] - 1
          when :jump then i = ins[1] - 1
          end
          i += 1
        end
        list
      end

      def emit(entries, declared, lines, indent)
        entries.each do |e|
          case e
          when Repeat
            lines << "#{indent}repeat #{e.count} do"
            emit(e.steps, declared, lines, indent + '  ')
            lines << "#{indent}end"
          when Label
            lines << "#{indent}label #{e.name.inspect}"
          when Goto
            lines << "#{indent}#{goto_ruby(e)}"
          when Pick
            emit_pick(e, declared, lines, indent)
          when Play
            if declared[e.name]
              lines << "#{indent}#{e.name}#{e.times ? " times: #{e.times}" : ''}"
            else
              declared[e.name] = true
              s = @sections[e.name]
              opts = s.options
              opts[:times] = e.times if e.times
              parts = [Form.ruby_value(s.length), *opts.map { |k, v| "#{k}: #{Form.ruby_value(v)}" }]
              lines << "#{indent}#{e.name} #{parts.join(', ')}"
            end
          end
        end
      end

      def goto_ruby(e)
        times = e.times ? ", times: #{e.times}" : ''
        case e.target
        when Hash
          "goto #{e.target.map { |k, w| "#{k}: #{Form.ruby_value(w)}" }.join(', ')}#{times}"
        when Proc
          src = e.target.source_location
          "goto #{Form.ruby_value(e.target)}#{times} # a Proc from #{src ? src.join(':') : 'somewhere'}; can't print its code"
        else
          "goto #{e.target.inspect}#{times}"
        end
      end

      # A pick as `pick :a, :b`, `pick a: 3, b: 1`, or a block of options.
      def emit_pick(e, declared, lines, indent)
        simple = e.options.all? { |o| o.steps.length == 1 && o.steps[0].is_a?(Play) && o.steps[0].times.nil? && declared[o.steps[0].name] }
        names = e.options.map { |o| o.steps[0]&.name }
        if simple && e.options.all? { |o| o.weight == 1 }
          lines << "#{indent}pick #{names.map(&:inspect).join(', ')}"
        elsif simple && names.uniq.length == names.length
          lines << "#{indent}pick #{e.options.map { |o| "#{o.steps[0].name}: #{Form.ruby_value(o.weight)}" }.join(', ')}"
        else
          lines << "#{indent}pick do |p|"
          e.options.each do |o|
            w = Form.ruby_value(o.weight)
            inner = []
            emit(o.steps, declared, inner, '')
            if inner.empty?
              lines << "#{indent}  p.option(#{w}) { }"
            elsif inner.length == 1 && !inner[0].include?('#')
              lines << "#{indent}  p.option(#{w}) { #{inner[0]} }"
            else
              lines << "#{indent}  p.option(#{w}) do"
              inner.each { |l| lines << "#{indent}    #{l}" }
              lines << "#{indent}  end"
            end
          end
          lines << "#{indent}end"
        end
      end
    end
  end
end
