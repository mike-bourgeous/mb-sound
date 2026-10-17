# Golden text captures (ux-1 r3, pattern E and item 32g): whole screens as
# text files under spec/lib/mb/sound/ui/golden/, compared line by line;
# MB_SOUND_UPDATE_GOLDEN=1 rewrites them (review the diff before
# committing).  A mismatch writes the actual text next to the golden file
# as NAME.actual.txt (gitignored by its suffix) and an HTML side-by-side
# (NAME.diff.html) for a quick look.
module GoldenHelpers
  GOLDEN_DIR = File.expand_path('../lib/mb/sound/ui/golden', __dir__)

  def expect_golden(name, text)
    path = File.join(GOLDEN_DIR, "#{name}.txt")
    text = text.lines.map(&:rstrip).join("\n").sub(/\n+\z/, '') + "\n"
    if ENV['MB_SOUND_UPDATE_GOLDEN'] == '1' || !File.exist?(path)
      if ENV['CI'] && !File.exist?(path)
        raise "Golden capture #{path} is missing (MB_SOUND_UPDATE_GOLDEN=1 writes it)"
      end
      File.write(path, text)
      return
    end
    golden = File.read(path)
    return if golden == text

    actual = path.sub(/\.txt\z/, '.actual.txt')
    File.write(actual, text)
    html = path.sub(/\.txt\z/, '.diff.html')
    esc = ->(t) { t.gsub('&', '&amp;').gsub('<', '&lt;') }
    File.write(html, "<!doctype html><meta charset=utf-8><title>#{name}</title><style>pre{font:12px monospace;display:inline-block;vertical-align:top;margin:1em;border:1px solid #888}</style>" \
                     "<pre>#{esc.(golden)}</pre><pre>#{esc.(text)}</pre>")
    first = golden.lines.zip(text.lines).index { |a, b| a != b }
    raise RSpec::Expectations::ExpectationNotMetError,
          "#{name}: screen differs from #{path} at line #{first.to_i + 1}\n  golden: #{golden.lines[first.to_i]&.chomp.inspect}\n  actual: #{text.lines[first.to_i]&.chomp.inspect}\n" \
          "(actual in #{actual}, side by side in #{html}; MB_SOUND_UPDATE_GOLDEN=1 accepts it)"
  end
end

RSpec.configure do |c|
  c.include GoldenHelpers
end
