# The param guard (param-1): every declared parameter in the library
# (lib/ tables, presets/ documents, bin/ script options) must build what
# its readers need: a help line, a knob (numbers with a bounded range, or a
# default inside a knob's 0..1), and a graph-document line that loads back
# as the same MB::Sound::Param (plain-number defaults: documents hold
# numbers), with the default inside its range.
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

  # True if +param+ fits a graph document's `param` line: a plain-number
  # default (documents hold numbers) and a plain-number range, if any.
  def document?(param)
    plain = ->(v) { v.is_a?(Integer) || v.is_a?(Float) }
    plain.(param.default) && (param.range.nil? || (param.range.is_a?(Range) && [param.range.begin, param.range.end].all?(&plain)))
  end
end
