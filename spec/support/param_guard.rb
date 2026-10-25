# The param guard (param-1): every declared parameter in the library
# (lib/ tables, presets/ documents, bin/ script options) must build what
# its readers need: a help line, a knob (numbers with a bounded range, or a
# default inside a knob's 0..1), and a graph-document line that loads back
# as the same MB::Sound::Param (numbers and unit values, as format 5
# documents write them), with the default inside its range.
module ParamGuard
  module_function

  # Problems with +param+ (an MB::Sound::Param) as an Array of Strings,
  # and what was built ({ knob: bool, document: bool }).
  def check(param)
    problems = []
    built = { knob: false, document: false }

    begin
      param.check(param.default) unless param.default.nil?
    rescue ArgumentError => e
      problems << "default: #{e.message}"
    end

    line = param.help_line
    problems << "help line #{line.inspect} doesn't start with the name" unless line.start_with?(param.name.to_s)

    if knob?(param)
      begin
        spec = param.knob_spec
        problems << "knob #{spec.to_ruby} lost the default" unless (spec.default - MB::Sound::Param.magnitude(param.default || spec.range.begin)).abs <= 1e-9 * [1, spec.default.abs].max
        built[:knob] = true
      rescue ArgumentError => e
        problems << "knob: #{e.message}"
      end
    end

    if document?(param)
      begin
        text = "graph #{MB::Sound::GraphIO::FORMAT}\n#{param.document_line}\n1.constant\n"
        back = MB::Sound::GraphIO.parse(text).declarations[param.name]
        problems << "document line #{param.document_line.inspect} loads as #{back.inspect}" unless back == param
        built[:document] = true
      rescue ArgumentError, MB::Sound::GraphIO::LoadError => e
        problems << "document line #{param.document_line.inspect}: #{e.message}"
      end
    end

    result = Prism.parse(param.to_ruby)
    problems << "to_ruby #{param.to_ruby.inspect} isn't Ruby" unless result.errors.empty?

    [problems, built]
  end

  # True if a knob can hold +param+: a number or unit value with a bounded
  # range, or none and a default a 0..1 knob holds.
  def knob?(param)
    return false unless param.numeric?
    return param.bounded? if param.range
    param.default.nil? || MB::Sound::Param.magnitude(param.default).between?(0, 1)
  end

  # True if +param+ fits a graph document's `param` line (format 5): a
  # number or unit-value default (2400.hz) and a range of them, if any.
  def document?(param)
    value = ->(v) { (v.is_a?(Numeric) && v.real?) || MB::Sound::Param::UNIT_TYPES.include?(MB::Sound::Param.type_of(v)) }
    value.(param.default) && (param.range.nil? || (param.range.is_a?(Range) && [param.range.begin, param.range.end].all?(&value)))
  end
end

module ParamGuard
  # Knob declarations written as literals in Ruby source (`knob :cut,
  # (150.hz..8000.hz).at(2400.hz)` in a song block, a genre, a rack):
  # [[file:line, Param or nil, skip reason or nil], ...] for every `knob`
  # call with a Symbol name and a value in +files+.  Each is read as a
  # graph-document knob line (literals only; the loader refuses variables
  # and other calls, which are skipped with the reason).
  def self.source_knobs(files)
    out = []
    files.each do |file|
      tree = Prism.parse_file(file).value
      stack = [tree]
      until stack.empty?
        n = stack.pop
        next unless n
        stack.concat(n.compact_child_nodes)
        next unless n.is_a?(Prism::CallNode) && n.name == :knob && n.receiver.nil?
        args = n.arguments&.arguments || []
        next unless args.length >= 2 && args[0].is_a?(Prism::SymbolNode)
        where = "#{file}:#{n.location.start_line}"
        text = "graph #{MB::Sound::GraphIO::FORMAT}\nknob #{n.arguments.slice}\n1.constant\n"
        begin
          doc = MB::Sound::GraphIO.parse(text)
          out << [where, doc.declarations.values.first, nil]
        rescue MB::Sound::GraphIO::LoadError => e
          raise unless e.message.match?(/undefined name|isn't a graph method|holds values only|share: and follow:|needs a number|unknown constant|unknown knob option/)
          out << [where, nil, e.message.lines.first.strip]
        end
      end
    end
    out
  end
end
