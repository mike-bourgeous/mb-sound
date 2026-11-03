# RSpec's JSON formatter, writing every string as valid UTF-8 (invalid or
# binary bytes become U+FFFD), for `rake spec:parallel`'s per-process
# reports.  The batch-10 suite (2026-11-03) lost a whole process's report
# (1248 examples) when one string in its output hash was ASCII-8BIT with a
# byte over 0x7F: JsonFormatter#close raised Encoding::UndefinedConversionError
# after every example had passed, and the runner could only call the
# process crashed.  Scrubbing keeps the report; the odd string still shows
# (with replacement characters) wherever it was.
require 'rspec/core/formatters/json_formatter'

class SafeJsonFormatter < RSpec::Core::Formatters::JsonFormatter
  RSpec::Core::Formatters.register self, :message, :dump_summary, :dump_profile, :stop, :seed, :close

  # +value+ with every String in it (nested Hashes and Arrays included) as
  # valid UTF-8.
  def self.scrub(value)
    case value
    when String
      s = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.scrub("�")
    when Hash
      value.to_h { |k, v| [scrub(k), scrub(v)] }
    when Array
      value.map { |v| scrub(v) }
    else
      value
    end
  end

  def close(_notification)
    output.write self.class.scrub(output_hash).to_json
  end
end
