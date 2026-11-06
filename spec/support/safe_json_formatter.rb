# RSpec's JSON formatter, writing every string as valid UTF-8 (invalid or
# binary bytes become U+FFFD), for `rake spec:parallel`'s per-process
# reports.  The batch-10 suite (2026-11-03) lost a whole process's report
# (1248 examples) when one string in its output hash was ASCII-8BIT with a
# byte over 0x7F: JsonFormatter#close raised Encoding::UndefinedConversionError
# after every example had passed, and the runner could only call the
# process crashed.  Scrubbing keeps the report; the odd string still shows
# (with replacement characters) wherever it was.
#
# fix-batch-1106: the source of that string wasn't found (not reproduced in
# process 6's files with its seed, in the batch's changed files, or in a
# whole SLOW=1 suite with this logging), so each scrubbed string is also
# listed under the report's "scrubbed" key with its place in the hash
# (e.g. "examples/412/pending_message", "messages/0"), its encoding, and
# its first bytes, and rake spec:parallel prints them: a recurrence names
# its source.
require 'rspec/core/formatters/json_formatter'

class SafeJsonFormatter < RSpec::Core::Formatters::JsonFormatter
  RSpec::Core::Formatters.register self, :message, :dump_summary, :dump_profile, :stop, :seed, :close

  # +value+ with every String in it (nested Hashes and Arrays included) as
  # valid UTF-8.  Strings that weren't valid UTF-8 already (or couldn't be
  # converted to it) are added to +found+ as { path:, encoding:, start: }
  # (+path+ the keys and indices leading to the string, joined with /).
  def self.scrub(value, found = [], path = [])
    case value
    when String
      return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?
      return value.encode(Encoding::UTF_8) if value.ascii_only? || convertible?(value)
      found << { path: path.join('/'), encoding: value.encoding.name, start: value.byteslice(0, 120).b.inspect }
      s = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.scrub("�")
    when Hash
      value.to_h { |k, v| [scrub(k, found, path + ['(key)']), scrub(v, found, path + [k])] }
    when Array
      value.each_with_index.map { |v, i| scrub(v, found, path + [i]) }
    else
      value
    end
  end

  # True if +s+ (not UTF-8) converts to UTF-8 (a valid string of a text
  # encoding; never ASCII-8BIT with bytes over 0x7F, which to_json can't).
  def self.convertible?(s)
    return false if s.encoding == Encoding::ASCII_8BIT || s.encoding == Encoding::UTF_8
    s.valid_encoding? && s.encode(Encoding::UTF_8) && true
  rescue EncodingError
    false
  end

  def close(_notification)
    found = []
    hash = self.class.scrub(output_hash, found)
    hash[:scrubbed] = found unless found.empty?
    output.write hash.to_json
  end
end
