require_relative 'form/builder'
require_relative 'form/state'
require_relative 'form/playback'

module MB
  module Sound
    # A song form: named sections (each launching a scene of the same name
    # for some bars) in a play order, with repeats, follow actions that
    # choose what comes next, fills at the ends of sections, and phrase
    # fills every few bars.  Built with a block (see Form::Builder), played
    # by an Arrangement (see Form::Playback), and printed back as the same
    # Ruby block by #to_ruby (so `take.form` can show what was played as
    # code to paste).  See design/notes/arrangement.md.
    #
    #     flow do
    #       intro  4.bars
    #       verse  8.bars, times: 2, next: { chorus: 3, drop: 1 }   # weighted follow action
    #       chorus 8.bars, fill: :roll
    #       repeat 2 do
    #         verse
    #         chorus
    #       end
    #       drop   16.bars, fill: [:riser, 4.bars]
    #       outro  8.bars, next: :end
    #     end
    #
    # Lengths are Durations (8.bars, 6.beats) or plain numbers of bars
    # (counted in the meter where the section starts).  Trap: `verse 8.bars
    # * 2` is one 16-bar verse; write `verse 8.bars, times: 2` (or call it
    # twice) for two plays.
    class Form
      # Follow actions besides section names, Hashes of weights, and Procs.
      ACTIONS = [:next, :again, :end].freeze

      # When a section's fill plays: at the end of every pass (:pass, the
      # default) or only when the form leaves the section (:leave).
      FILL_ON = [:pass, :leave].freeze

      # A section: its +name+, +length+ (a Duration, or a number of bars),
      # how many passes it plays (+times+), its follow action (+next_action+:
      # :next, :again, :end, a section name, a Hash from actions to weights,
      # or a Proc given a Form::State), its +fill+ (nil, or a Fill), the
      # scene it launches (+scene+: nil for the scene named like the
      # section, false for none), and a launch +fade+ in bars (nil for the
      # scene's own).
      Section = Data.define(:name, :length, :times, :next_action, :fill, :scene, :fade) do
        def initialize(name:, length:, times: 1, next_action: :next, fill: nil, scene: nil, fade: nil)
          raise ArgumentError, "Section names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          Form.check_length(name, length)
          raise ArgumentError, "#{name}: times: must be a positive Integer (got #{times.inspect})" unless times.is_a?(Integer) && times > 0
          Form.check_action(name, next_action)
          raise ArgumentError, "#{name}: scene: must be a Symbol, false, or nil (got #{scene.inspect})" unless scene.nil? || scene == false || scene.is_a?(Symbol)
          super
        end

        # The keyword options that rebuild this section (for #to_ruby).
        def options
          opts = {}
          opts[:times] = times if times != 1
          opts[:next] = next_action if next_action != :next
          opts[:fill] = fill.to_option if fill
          opts[:scene] = scene unless scene.nil?
          opts[:fade] = fade unless fade.nil?
          opts
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

      # One entry in the play order: a section played (+name+, with a
      # per-step +times+ or nil for the section's), or a repeated group
      # (+count+ and +steps+).
      Play = Data.define(:name, :times)
      Repeat = Data.define(:count, :steps)

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

      # Raises unless +action+ is a follow action (see Section).
      def self.check_action(name, action)
        case action
        when Symbol, Proc
          nil
        when Hash
          bad = action.reject { |k, w| k.is_a?(Symbol) && w.is_a?(Numeric) && w >= 0 }
          raise ArgumentError, "#{name}: next: weights must be Symbol => number pairs (got #{bad.inspect})" unless bad.empty?
          raise ArgumentError, "#{name}: next: weights can't all be zero" unless action.values.sum > 0
        else
          raise ArgumentError, "#{name}: next: must be #{ACTIONS.map(&:inspect).join(', ')}, a section name, a Hash of weights, or a Proc (got #{action.inspect})"
        end
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
          src = value.source_location
          "->(f) { :next } # a Proc from #{src ? src.join(':') : 'somewhere'}; can't print its code"
        else
          value.inspect
        end
      end

      # The sections by name (a frozen Hash).
      attr_reader :sections

      # The play order: Play and Repeat entries (a frozen Array).
      attr_reader :order

      # Phrase fills (PhraseFill, a frozen Array).
      attr_reader :phrase_fills

      def initialize(sections:, order:, phrase_fills: [])
        @sections = sections.dup.freeze
        @order = order.dup.freeze
        @phrase_fills = phrase_fills.dup.freeze
        check_order(@order)
        freeze
      end

      # The order with repeats expanded: an Array of [section name, times]
      # (times from the step or the section).
      def steps
        expand(@order)
      end

      # The total length in bars of one straight pass through the order
      # with every section's +times+ (follow actions aside), counting
      # Durations at +bar_length+ (whole notes per bar).
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
      # (Procs in follow actions can't be printed and become comments).
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

      def check_order(entries)
        entries.each do |e|
          case e
          when Play
            raise ArgumentError, "No section #{e.name.inspect} in the form" unless @sections.key?(e.name)
          when Repeat
            check_order(e.steps)
          else
            raise ArgumentError, "Form order entries are Play or Repeat (got #{e.inspect})"
          end
        end
      end

      def expand(entries)
        entries.flat_map { |e|
          if e.is_a?(Repeat)
            Array.new(e.count) { expand(e.steps) }.flatten(1)
          else
            [[e.name, e.times || @sections[e.name].times]]
          end
        }
      end

      def emit(entries, declared, lines, indent)
        entries.each do |e|
          if e.is_a?(Repeat)
            lines << "#{indent}repeat #{e.count} do"
            emit(e.steps, declared, lines, indent + '  ')
            lines << "#{indent}end"
          elsif declared[e.name]
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
  end
end
