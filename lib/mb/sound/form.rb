require 'did_you_mean'

require_relative 'form/builder'
require_relative 'form/state'
require_relative 'form/walking'
require_relative 'form/plan'
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
      STEP_NAMES = [:repeat, :fill, :label, :goto, :pick, :generate].freeze

      # Methods the flow builder calls on MB::Sound for generate steps'
      # sources (not section names either).
      SOURCE_NAMES = [:markov, :lsystem, :knob].freeze

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
      # - Play: a section played (+name+, with a per-step +times+ and
      #   +length+, or nil for the section's).
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
      Play = Data.define(:name, :times, :length) do
        # +length+ is this play's own length (nil for the section's): the
        # same section may play for different lengths at different places
        # in the order (`chorus 16` ... `chorus 8`, G4).
        def initialize(name:, times: nil, length: nil)
          Form.check_length(name, length) unless length.nil?
          super
        end
      end
      Repeat = Data.define(:count, :steps)
      Label = Data.define(:name)
      Goto = Data.define(:target, :times)
      Pick = Data.define(:options)
      Option = Data.define(:weight, :steps)

      # A generate step (G4): plays sections drawn from +source+ (a
      # Generative::Markov or LSystem, or anything with the same form
      # source methods: #form_start, #form_next, #form_states,
      # #nonterminal?, #form_force, #steered?, #seed, #to_ruby) one at a
      # time as the flow plays, each decided at the commit point before it
      # (so a steered chain reads its knobs there), until the source ends
      # (a chain's end state, a word's last symbol) or, with +sections+,
      # that many per visit; then the flow carries on.  +lengths+ gives
      # sections their lengths per occurrence (bars, Durations, Ranges of
      # bars or Arrays drawn per occurrence from the source's seed);
      # sections without one play their declared length.  Every visit
      # continues the source where the last one left it (a chain's draws
      # keep counting), so `label :top; generate moods; goto :top` plays
      # on forever.
      Generate = Data.define(:source, :lengths, :sections) do
        def initialize(source:, lengths: {}, sections: nil)
          unless %i[form_start form_next form_states nonterminal? seed to_ruby].all? { |m| source.respond_to?(m) }
            raise ArgumentError, "generate needs a section source: markov(...) or lsystem(...) (got #{source.inspect})"
          end
          raise ArgumentError, "generate's lengths are a Hash of section => length (got #{lengths.inspect})" unless lengths.is_a?(Hash)
          lengths.each { |name, len| Form.check_length_spec(name, len) }
          raise ArgumentError, "generate sections: must be a positive Integer or nil (got #{sections.inspect})" unless sections.nil? || (sections.is_a?(Integer) && sections > 0)
          super(source: source, lengths: lengths.dup.freeze, sections: sections)
        end

        # The length of section +name+ for the source's draw +n+ (its own
        # length spec drawn, else +default+).
        def length_for(name, n, default)
          spec = lengths[name]
          spec.nil? ? default : Form.draw_length(spec, source.seed, n)
        end

        def to_ruby
          parts = [source.to_ruby]
          parts << "bars: #{Form.ruby_value(lengths)}" unless lengths.empty?
          parts << "sections: #{sections}" if sections
          "generate #{parts.join(', ')}"
        end
      end

      # Raises unless +spec+ is a generated section's length: a length, a
      # Range of whole bars, or an Array of lengths.
      def self.check_length_spec(name, spec)
        case spec
        when Range
          ok = spec.begin.is_a?(Integer) && spec.end.is_a?(Integer) && spec.begin > 0 && spec.size > 0
          raise ArgumentError, "#{name}: a Range of lengths is whole bars (4..8; got #{spec.inspect})" unless ok
        when Array
          raise ArgumentError, "#{name}: an Array of lengths needs at least one (got #{spec.inspect})" if spec.empty?
          spec.each { |l| check_length(name, l) }
        else
          check_length(name, spec)
        end
      end

      # A length from +spec+ (see #check_length_spec) for draw +n+ of a
      # source seeded with +seed+: Ranges and Arrays are drawn (counter-
      # based, so occurrence n always gets the same length).
      def self.draw_length(spec, seed, n)
        case spec
        when Range then Generative::Dice.new(seed, :length).int(spec, n)
        when Array then Generative::Dice.new(seed, :length).pick(spec, n)
        else spec
        end
      end

      # The declared length for a length spec (a Range's first bar count,
      # an Array's first length).
      def self.default_length(spec)
        case spec
        when Range then spec.begin
        when Array then spec.first
        else spec
        end
      end

      # A linear Form of sections in order (each declared where it first
      # plays) from +list+, [name, draw] pairs, with lengths from +lengths+
      # (name => length spec, drawn for each pair's draw number with
      # +seed+, as a generate step draws them).  For Markov#flow and
      # LSystem#flow.
      def self.linear(list, lengths, seed:)
        missing = list.map(&:first).uniq - lengths.keys
        raise ArgumentError, "No length for #{missing.map(&:inspect).join(', ')} (give each section a length: #{missing.first}: 8)" unless missing.empty?
        sections = {}
        order = list.map { |name, i|
          len = draw_length(lengths[name], seed, i)
          sections[name] ||= Section.new(name: name, length: len)
          Play.new(name: name, times: nil, length: same_length?(len, sections[name].length) ? nil : len)
        }
        new(sections: sections, order: order)
      end

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

      # True if section lengths +a+ and +b+ are the same (the same kind
      # too: 8 bars counted through the meter map aren't 8.bars).
      def self.same_length?(a, b)
        a.class == b.class && a == b
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
      # instructions, each a frozen Array: [:play, name, times, length]
      # (the play's own length, else the section's), [:label,
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
        straight.map { |i| @program[i][1..2] }
      end

      # Like #steps, with each play's length: [section name, times, length]
      # (lengths differ per play when a section plays for different lengths
      # in different places: `chorus 16` ... `chorus 8`).
      def plays
        straight.map { |i| @program[i].drop(1) }
      end

      # The total length in bars of #plays, counting Durations at
      # +bar_length+ (whole notes per bar).
      def bars(bar_length: 1r)
        plays.sum { |_name, times, len|
          (len.is_a?(Sequence::Duration) ? len.to_r / bar_length : len.to_r) * times
        }
      end

      # A copy with every section, play, fill, and phrase fill length
      # passed through the block (`form.map_lengths { |len| ... }`; the
      # block gets each length and what it belongs to: :section, :play,
      # :fill, :every (a phrase fill's period), or :phrase_fill).
      def map_lengths(&block)
        sections = @sections.transform_values { |s|
          s.with(length: block.call(s.length, :section), fill: s.fill && s.fill.with(length: block.call(s.fill.length, :fill)))
        }
        fills = @phrase_fills.map { |f| f.with(every: block.call(f.every, :every), length: block.call(f.length, :phrase_fill)) }
        Form.new(sections: sections, order: map_order_lengths(@order, block), phrase_fills: fills)
      end

      # True if the form has generate steps (sections decided as it plays).
      def generative?
        @program.any? { |ins| ins[0] == :generate }
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
          when Generate
            check_generate(e)
          else
            raise ArgumentError, "Form order entries are Play, Repeat, Label, Goto, Pick, or Generate (got #{e.inspect})"
          end
        end
      end

      # A generate step's sections: every name its source may give is a
      # section of the form (declared, or given a length in the step),
      # except nonterminals (an L-system's rewritten symbols) without one.
      def check_generate(e)
        e.lengths.each_key { |n| check_section(n) }
        names = e.source.form_states.reject { |n| e.source.nonterminal?(n) && !@sections.key?(n) }
        missing = names.reject { |n| @sections.key?(n) }
        return if missing.empty?
        raise ArgumentError, "generate #{e.source.to_ruby}: no length for #{missing.map(&:inspect).join(', ')} " \
          "(give it one: generate ..., bars: { #{missing.first}: 8 }, or declare it in the flow)"
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
            if li <= i && @program[li...i].none? { |x| x[0] == :play || x[0] == :generate }
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
            out << [:play, e.name, e.times || @sections[e.name].times, e.length || @sections[e.name].length].freeze
          when Repeat
            e.count.times { compile(e.steps, out) }
          when Label
            out << [:label, e.name].freeze
          when Goto
            out << [:goto, e.target, e.times].freeze
          when Generate
            out << [:generate, e].freeze
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
          when Generate
            lines << "#{indent}#{e.to_ruby}"
            # (the step declares the sections it gives lengths to)
            e.lengths.each_key { |n| declared[n] ||= @sections[n].length }
          when Play
            s = @sections[e.name]
            len = e.length || s.length
            if declared.key?(e.name)
              # (a length where this play's differs from the declared one)
              parts = Form.same_length?(len, declared[e.name]) ? [] : [Form.ruby_value(len)]
              parts << "times: #{e.times}" if e.times
              lines << "#{indent}#{e.name}#{" #{parts.join(', ')}" unless parts.empty?}"
            else
              # Declared where it first plays, with that play's length
              declared[e.name] = len
              opts = s.options
              opts[:times] = e.times if e.times
              parts = [Form.ruby_value(len), *opts.map { |k, v| "#{k}: #{Form.ruby_value(v)}" }]
              lines << "#{indent}#{e.name} #{parts.join(', ')}"
            end
          end
        end
      end

      # +entries+ with every Play's own length passed through +block+.
      def map_order_lengths(entries, block)
        entries.map { |e|
          case e
          when Play then e.length ? e.with(length: block.call(e.length, :play)) : e
          when Repeat then e.with(steps: map_order_lengths(e.steps, block).freeze)
          when Pick then e.with(options: e.options.map { |o| o.with(steps: map_order_lengths(o.steps, block).freeze) }.freeze)
          when Generate
            e.with(lengths: e.lengths.transform_values { |spec|
              case spec
              when Range then (block.call(spec.begin, :generate)..block.call(spec.end, :generate))
              when Array then spec.map { |l| block.call(l, :generate) }
              else block.call(spec, :generate)
              end
            })
          else e
          end
        }
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
        simple = e.options.all? { |o|
          st = o.steps[0]
          o.steps.length == 1 && st.is_a?(Play) && st.times.nil? && declared.key?(st.name) &&
            Form.same_length?(st.length || @sections[st.name].length, declared[st.name])
        }
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
