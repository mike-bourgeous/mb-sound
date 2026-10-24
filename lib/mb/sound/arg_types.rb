require 'did_you_mean'

module MB
  module Sound
    # Type-dispatched parameters: a small classifier for argument values
    # (a Tempo, a Rational ratio, a length in seconds, a frequency, a
    # named thing, ...) and declared tables that give a method's
    # arguments their meaning by type rather than by position.
    #
    # - ArgTypes.classify(value): the value's type (see TYPES), or :number /
    #   :node for plain numbers and graph nodes nothing tagged (untyped:
    #   they keep their positional meaning).
    # - Signature: a method's typed parameters.  Precedence is keyword >
    #   type > position (maintainer, 2026-10-18): every typed parameter has
    #   a keyword that places plain numbers or untagged nodes
    #   unambiguously; typed values find the one parameter taking their
    #   type, wherever they are written; untyped values fill the remaining
    #   parameters in declared order.  A typed value two open parameters
    #   take, or one no parameter takes, raises with the keywords to use.
    #   #canonical prints parameters as keywords in declared order (only
    #   when they differ from their defaults), the primary argument (a
    #   preset, a pattern, a length) positional.
    # - Dispatch: one method name whose meaning depends on its argument's
    #   type (Clip#at, #over, #%), one declared table per receiver; errors
    #   and `help :at` are generated from the table, and every row names the
    #   canonical method it calls, which is what graphs print.
    #
    # Nodes producing a frequency (v.hz, v.freq, node.freq) are tagged
    # (#tag, a weak table: no instance variables, printed nowhere) so a
    # later toolkit method can tell `rain.peq(h, midi.freq)`'s frequency
    # from its other inputs.  See design/notes/arg_types.md.
    module ArgTypes
      # A value type: its name, what it is in words, an example, and its
      # test.
      Type = Data.define(:name, :description, :example, :test)

      # Value types, tested in order (Decibels before plain numbers, Note
      # before Pitch's frequency).
      TYPES = [
        Type.new(:tempo, 'a tempo', '138.75.bpm', ->(v) { v.is_a?(MB::Sound::Tempo) }),
        Type.new(:ratio, 'a Rational ratio', '5/4r', ->(v) { v.is_a?(Rational) }),
        Type.new(:seconds, 'a length in seconds', '19.7.seconds', ->(v) { v.is_a?(MB::Sound::Length::Seconds) }),
        Type.new(:samples, 'a length in samples', '480.samples', ->(v) { v.is_a?(MB::Sound::Length::Samples) }),
        Type.new(:duration, 'a musical length', '2.bars', ->(v) { v.is_a?(MB::Sound::Sequence::Duration) }),
        Type.new(:decibels, 'a level in dB', '-6.db', ->(v) { v.is_a?(MB::Sound::Decibels) }),
        Type.new(:interval, 'an interval', '7.semitones', ->(v) { v.is_a?(MB::Sound::Interval) }),
        Type.new(:phase, 'a phase', '0.25.cycles', ->(v) { v.is_a?(MB::Sound::Phase) }),
        Type.new(:curve, 'a curve', 'Curve[:smooth]', ->(v) { v.is_a?(MB::Sound::Curve) }),
        Type.new(:frequency, 'a frequency', '220.hz or v.freq', ->(v) { ArgTypes.frequency?(v) }),
        Type.new(:notes, 'notes', 'a clip or v (Notes)', ->(v) { v.is_a?(MB::Sound::Sequence::Clip) || v.is_a?(MB::Sound::Notes) || v.is_a?(MB::Sound::MIDI::Stream) }),
        Type.new(:name, 'a name', ':tide', ->(v) { v.is_a?(Symbol) }),
      ].freeze

      # Untyped kinds: they keep their positional meaning.
      UNTYPED = {
        number: 'a plain number',
        node: 'a graph node',
      }.freeze

      TYPE_INDEX = TYPES.to_h { |t| [t.name, t] }.freeze

      # Every type name, typed and untyped.
      def self.type_names
        TYPE_INDEX.keys + UNTYPED.keys
      end

      # Tags on graph nodes (identity-keyed, weak: tagging never keeps a
      # node alive or changes its instance variables).
      TAGS = ObjectSpace::WeakMap.new

      # Tags +node+ as producing +type+ (e.g. :frequency) and returns it.
      def self.tag(node, type)
        raise ArgumentError, "Unknown type #{type.inspect}" unless TYPE_INDEX.key?(type)
        TAGS[node] = type unless node.nil?
        node
      end

      # The tag of +node+ (see #tag), or nil.
      def self.tag_of(node)
        TAGS[node]
      rescue StandardError
        nil
      end

      # True if +v+ is a frequency: a Pitch (Notes included), a
      # Notes::Frequency, or a node tagged :frequency.
      def self.frequency?(v)
        v.is_a?(MB::Sound::Pitch) || (defined?(MB::Sound::Notes::Frequency) && v.is_a?(MB::Sound::Notes::Frequency)) || TAGS[v] == :frequency
      end

      # The type of +value+: a TYPES name, :number for plain numbers,
      # :node for other graph nodes, or nil (something else).
      def self.classify(value)
        TYPES.each { |t| return t.name if t.test.(value) }
        return :number if value.is_a?(Numeric)
        return :node if value.respond_to?(:sample) || value.is_a?(GraphNode)
        nil
      end

      # Words for type +name+ ("a tempo (138.75.bpm)").
      def self.describe(name)
        t = TYPE_INDEX[name]
        return "#{t.description} (#{t.example})" if t
        UNTYPED.fetch(name) { name.to_s }
      end

      # A value's type in words for messages ("a plain number 2").
      def self.describe_value(value)
        type = classify(value)
        text = value.respond_to?(:to_ruby) ? value.to_ruby : value.inspect
        text = "#{text[0, 40]}..." if text.length > 43
        type ? "#{type == :number || type == :node ? UNTYPED[type] : TYPE_INDEX[type].description} (#{text})" : "#{value.class} (#{text})"
      end

      # Raised for arguments a table can't place.  #suggestions are the
      # spellings that would work.
      class ArgumentTypeError < ArgumentError
        attr_reader :suggestions

        def initialize(message, suggestions = [])
          @suggestions = suggestions
          super(suggestions.empty? ? message : "#{message}\n  Did you mean?  #{suggestions.join("\n                 ")}")
        end
      end

      # A typed parameter is an MB::Sound::Param (lib/mb/sound/param.rb,
      # which sets ArgTypes::Param): +name+ (also its keyword unless
      # +keyword+ says otherwise), +types+ ({ type => meaning in words }),
      # its +default+ (canonical forms leave defaults out), and whether it
      # is the method's +primary+ argument (printed positionally).

      # The declared typed parameters of one method (see ArgTypes).
      class Signature
        attr_reader :name, :receiver, :params

        # +name+ is the method, +receiver+ the receiver in words ("a
        # clip"), +params+ an Array of Params in declared order.
        def initialize(name, receiver:, params:)
          @name = name
          @receiver = receiver
          @params = params.freeze
          @by_keyword = params.to_h { |p| [p.keyword, p] }.freeze
          freeze
        end

        # The parameter named or keyed +k+.
        def param(k)
          @by_keyword[k] || @params.find { |p| p.name == k }
        end

        # Places +args+ (positional) and +kwargs+ (keywords of this
        # signature; others are left in the returned Hash's :rest) on the
        # parameters: { param name => value, ..., rest: { other keywords } }.
        # Keyword first, then type, then position (see ArgTypes).
        def bind(args, kwargs = {})
          out = {}
          rest = {}
          kwargs.each do |k, v|
            p = @by_keyword[k]
            if p
              out[p.name] = v
            else
              rest[k] = v
            end
          end

          untyped = []
          args.each do |v|
            type = ArgTypes.classify(v)
            if type.nil? || ArgTypes::UNTYPED.key?(type)
              untyped << v
              next
            end
            open = @params.select { |p| p.takes?(type) && !out.key?(p.name) }
            if open.length == 1
              out[open[0].name] = v
            elsif open.empty?
              taken = @params.select { |p| p.takes?(type) }
              if taken.empty?
                raise ArgumentTypeError.new("#{@name} doesn't take #{ArgTypes.describe_value(v)}; it takes:\n#{table_text}", keyword_hints(v))
              end
              raise ArgumentTypeError.new("#{@name} got #{ArgTypes.describe_value(v)} for #{taken.map { |p| p.keyword.inspect }.join(' or ')}, which already has a value", [])
            else
              raise ArgumentTypeError.new(
                "#{@name}: #{ArgTypes.describe_value(v)} could be #{open.map { |p| "#{p.keyword}: (#{p.types[type]})" }.join(' or ')}; say which with a keyword",
                open.map { |p| "#{p.keyword}: #{ArgTypes.value_text(v)}" }
              )
            end
          end

          # Untyped values: the open parameters taking them, in order
          untyped.each do |v|
            type = ArgTypes.classify(v)
            p = @params.find { |x| !out.key?(x.name) && (type.nil? || x.takes?(type)) }
            unless p
              raise ArgumentTypeError.new("#{@name} has no place for #{ArgTypes.describe_value(v)}; it takes:\n#{table_text}", keyword_hints(v))
            end
            out[p.name] = v
          end

          out[:rest] = rest unless rest.empty?
          out
        end

        # [positional, keywords] for printing +values+ (a Hash from param
        # name to value) in canonical form: the primary parameter
        # positional, the others as keywords in declared order when they
        # differ from their defaults.
        def canonical(values)
          pos = []
          kw = {}
          @params.each do |p|
            next unless values.key?(p.name)
            v = values[p.name]
            if p.primary
              pos << v
            elsif !(v == p.default)
              kw[p.keyword] = v
            end
          end
          [pos, kw]
        end

        # Table rows: [keyword, type, meaning].
        def rows
          @params.flat_map { |p| p.types.map { |type, meaning| [p.keyword, type, meaning] } }
        end

        # The table as text (for errors and help).
        def table_text
          rows.map { |k, type, meaning| "    #{"#{k}:".ljust(10)} #{ArgTypes.describe(type)}: #{meaning}" }.join("\n")
        end

        private

        def keyword_hints(v)
          type = ArgTypes.classify(v)
          return [] unless type.nil? || ArgTypes::UNTYPED.key?(type)
          @params.reject(&:primary).map { |p| "#{p.keyword}: #{ArgTypes.value_text(v)}" }
        end
      end

      # A method whose one argument's type picks what it does (Clip#at,
      # #over, #%): +rows+ is { type => [canonical method, meaning in
      # words] }.  #call sends the canonical method; anything else raises
      # with the table (and, for plain numbers, the spellings that would
      # work).
      class Dispatch
        attr_reader :name, :receiver, :rows, :note, :fallback_meaning

        # +name+ the method, +receiver+ the receiver in words, +rows+ the
        # table, +fallback+ a Proc for argument types not in the table (the
        # method's older meaning, e.g. Sample#at's offsets), +note+ a line
        # for help.
        def initialize(name, receiver:, rows:, fallback: nil, fallback_meaning: nil, note: nil)
          bad = rows.keys - ArgTypes.type_names
          raise ArgumentError, "Unknown types #{bad.inspect}" unless bad.empty?
          @name = name
          @receiver = receiver
          @rows = rows.freeze
          @fallback = fallback
          @fallback_meaning = fallback_meaning
          @note = note
          freeze
        end

        # The table row for +value+ ([method, meaning]), or nil.
        def row_for(value)
          @rows[ArgTypes.classify(value)]
        end

        # Calls the row's method for +value+ on +receiver+ (+kwargs+ passed
        # on), or the fallback, or raises the table.
        def call(receiver, value, *more, **kwargs)
          if (row = row_for(value))
            return receiver.public_send(row[0], value, *more, **kwargs)
          end
          return @fallback.(receiver, value, *more, **kwargs) if @fallback
          raise error(value)
        end

        # The error for an argument the table doesn't take.
        def error(value)
          hints = @rows.filter_map { |type, (_m, _meaning)|
            ex = ArgTypes.example_for(type, value)
            ex && (@name == :% ? "% #{ex}" : ".#{@name}(#{ex})")
          }
          ArgumentTypeError.new("#{@receiver.capitalize}'s ##{@name} doesn't take #{ArgTypes.describe_value(value)}; by type it means:\n#{table_text}", hints)
        end

        # The table as text (for errors and help).
        def table_text
          lines = @rows.map { |type, (m, meaning)| "    #{ArgTypes.describe(type).ljust(34)} #{meaning} (#{m})" }
          lines << "    #{'anything else'.ljust(34)} #{@fallback_meaning}" if @fallback_meaning
          lines << "    #{@note}" if @note
          lines.join("\n")
        end
      end

      # Ruby text for +v+ in a suggestion.
      def self.value_text(v)
        v.respond_to?(:to_ruby) ? v.to_ruby : v.inspect
      end

      # A spelling of +value+ (a plain number) as +type+, for suggestions
      # ("19.7.seconds"), or nil.
      def self.example_for(type, value)
        return nil unless value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels) && value.real?
        case type
        when :tempo then "#{value}.bpm"
        when :ratio then value.is_a?(Integer) ? "#{value}r" : "#{value.to_r.rationalize(Rational(1, 1000))}r".sub(%r{\A(\d+)/(\d+)r\z}, '\1/\2r')
        when :seconds then "#{value}.seconds"
        when :samples then "#{value.round}.samples"
        when :duration then "#{value}.bars"
        when :decibels then "#{value}.db"
        when :frequency then "#{value}.hz"
        end
      end

      # Declared tables, by [receiver class name, method] (for help and the
      # guard spec).
      REGISTRY = {}

      # Registers a Signature or Dispatch under +key+ and returns it.
      def self.register(key, table)
        REGISTRY[key] = table
      end

      # Tables registered for method +name+ ({ key => table }).
      def self.tables_for(name)
        REGISTRY.select { |(_r, m), _t| m == name }
      end
    end
  end
end
