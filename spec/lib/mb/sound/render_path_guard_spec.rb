require 'prism'

# Guards for bug classes found by the fuzzers and allocation audits of
# 2026-10-25 (omnibus13), as code patterns in lib/: each new match must be
# fixed or listed here with the reason it is fine.  Entries name the file
# and a piece of the matching code (not line numbers, so edits elsewhere
# don't break them).
RSpec.describe('render path code guards') do
  LIB = File.expand_path('../../../../lib', __dir__)

  def lib_files
    Dir[File.join(LIB, '**', '*.rb')].sort
  end

  def rel(path) = path.delete_prefix("#{File.dirname(LIB)}/")

  # Each file's syntax tree, parsed once for every example.
  TREES = {}
  def parsed(f) = (TREES[f] ||= Prism.parse_file(f).value)

  # Methods that run every buffer.
  RENDER_METHODS = /\A(sample|internal_sample|sample_c|sample_ruby|sample_internal|render\w*|process\w*|next_frame|read)\z/

  # Yields [file, method name, node] for every node in a method body, with
  # the method's locals assigned from a #sample call.
  def each_node_in_methods
    lib_files.each do |f|
      walk = lambda do |node, meth, sampled|
        return unless node
        if node.is_a?(Prism::DefNode)
          meth = node.name.to_s
          sampled = {}
        elsif node.is_a?(Prism::LocalVariableWriteNode) && sampled
          v = node.value
          sampled[node.name] = true if v.is_a?(Prism::CallNode) && v.name == :sample
        end
        yield rel(f), meth, node, sampled if meth
        node.compact_child_nodes.each { |c| walk.(c, meth, sampled) }
      end
      walk.(parsed(f), nil, nil)
    end
  end

  def unlisted(found, allowed)
    found.reject { |file, code| allowed.any? { |af, ac, _| af == file && code.include?(ac) } }
  end

  def unused(found, allowed)
    allowed.reject { |af, ac, _| found.any? { |file, code| af == file && code.include?(ac) } }
  end

  def report(list) = list.map { |f, c| "#{f}: #{c}" }.join("\n")

  # Numo's #fill allocates three objects a call; render paths fill with
  # BufferHelper.zero / BufferHelper.fill (alloc-2; omnibus13).
  FILL_ALLOWED = [
    ['lib/mb/sound/graph_node/four_pole.rb', 'Numo::SFloat.new(count).fill(@last[key])', 'pads an input that ended (once)'],
    ['lib/mb/sound/graph_node/multitap_delay.rb', 'Numo::SFloat.new(count).fill(delays)', 'smoothing a constant tap time (an option; allocates its buffer anyway; open: reuse one)'],
    ['lib/mb/sound/notes/poly_pressure.rb', 'Numo::SFloat.new(count).fill(v)', 'a new steady buffer only when the value changes'],
    ['lib/mb/sound/sq80.rb', 'Numo::SFloat.new(s.length).fill(value)', 'a new steady buffer only when the value changes'],
    ['lib/mb/sound/null_input.rb', 'Numo::SFloat.new(frames).fill(@fill)', 'grows the buffer (rarely)'],
    *%w[dynamics.rb dynamics/crossover.rb loudness_meter.rb rider.rb].map { |f| ["lib/mb/sound/graph_node/#{f}", '@sampled.fill(false)', 'an Array (no allocation)'] },
    ['lib/mb/sound/mastering/targeting.rb', '@sampled.fill(false)', 'an Array (no allocation)'],
    ['lib/mb/sound/graph_node/sub_lane.rb', '@out.fill(', 'an Array of outputs (no allocation)'],
  ].freeze

  it 'fills buffers in render methods without Numo#fill' do
    found = []
    each_node_in_methods do |file, meth, node, _|
      next unless meth.match?(RENDER_METHODS) && node.is_a?(Prism::CallNode) && node.name == :fill && node.receiver && node.arguments
      next if node.receiver.slice == 'BufferHelper'
      found << [file, node.slice]
    end
    allowed = FILL_ALLOWED.map { |f, c, r| [f, c, r] }
    bad = found.reject { |file, code| allowed.any? { |af, ac, _| file.start_with?(af) && code.include?(ac) } }
    expect(bad).to eq([]), "Numo#fill in render methods (use BufferHelper.zero or .fill, or list it with a reason):\n#{report(bad)}"
    stale = allowed.reject { |af, ac, _| found.any? { |file, code| file.start_with?(af) && code.include?(ac) } }
    stale = stale.map { |f, c, _| "#{f} #{c}" }
    expect(stale).to eq([]), "allowed #fill entries that no longer match anything (remove them): #{stale}"
  end

  # A parameter read from a sampled buffer's last sample applies one value
  # to the whole buffer, so its changes move with the buffer size (the
  # harmonics amplitudes and the wavetable wrap mode, fuzz-fixes-1 and
  # omnibus13).  Read per sample (or at the sample where it matters).
  LAST_ALLOWED = [
    ['lib/mb/sound/graph_node/four_pole.rb', 'data[-1]', 'remembers the last input to pad one that ends, not a parameter'],
    ['lib/mb/sound/graph_node/knob.rb', 'buf[-1]', 'holds a followed node\'s last value past its end'],
    ['lib/mb/sound/graph_node/zone_value.rb', 'num[-1]', 'a whole-buffer check before ptp; per sample otherwise'],
    ['lib/mb/sound/graph_node/zone_value.rb', 'vel[-1]', 'a whole-buffer check before ptp; per sample otherwise'],
  ].freeze

  it 'reads no parameter from the last sample of a sampled buffer' do
    found = []
    each_node_in_methods do |file, _meth, node, sampled|
      next unless node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::LocalVariableReadNode) && sampled&.key?(node.receiver.name)
      a = node.arguments&.arguments
      last = (node.name == :[] && a&.length == 1 && a[0].is_a?(Prism::IntegerNode) && a[0].value == -1) || (node.name == :last && a.nil?)
      found << [file, node.slice] if last
    end
    bad = unlisted(found, LAST_ALLOWED)
    expect(bad).to eq([]), "parameters read once per buffer (read them per sample, or list with a reason):\n#{report(bad)}"
    expect(unused(found, LAST_ALLOWED).map(&:first)).to eq([]), "unused entries: #{unused(found, LAST_ALLOWED)}"
  end

  # A Rational time times a Float rate is a Float, which floors to the
  # sample before an edge that lands exactly on a sample (fuzz-fixes-1's
  # frame counts).  Multiply by an Integer or Rational rate (rate.to_r).
  RATE_ALLOWED = [
    ['lib/mb/sound/ffmpeg_input.rb', '@info[:duration] || 0) * @sample_rate', 'a Float duration from ffprobe'],
    ['lib/mb/sound/ffmpeg_input.rb', '(start * @sample_rate).ceil', 'a Float start in seconds'],
    ['lib/mb/sound/synth.rb', '((last - t0) * rate).floor', 'rate is @sample_rate.to_r'],
    ['lib/mb/sound/synth.rb', '((time - from) * @sample_rate.to_r).floor', 'a Rational rate'],
    ['lib/mb/sound/graph_node/knob.rb', '((e.time - from) * @sample_rate.to_r).floor', 'a Rational rate'],
    ['lib/mb/sound/notes/node.rb', '((last - from) * step_rate).floor', 'step_rate is Rational (@rate_r)'],
    ['lib/mb/sound/midi/live_source.rb', '((to - from) * rate).ceil', 'rate is Integer(frame_rate)'],
    ['lib/mb/sound/midi/stream.rb', '((e.time - @spy_from) * rate).floor', 'rate is span.sample_rate.to_r (omnibus13)'],
    ['lib/mb/sound/graph_node/chorus_nodes.rb', '(@tail * @sample_rate).ceil', 'a Float tail in seconds'],
    ['lib/mb/sound/graph_node/constant.rb', '(timestamp * @sample_rate).floor', 'Float seconds from timed_change callers'],
    ['lib/mb/sound/notes/node.rb', '((time - from) * rate).floor', 'rate is @rate_r (Rational)'],
    ['lib/mb/sound/wavetable/builder.rb', '(valid * rate).ceil', 'a Float length in seconds'],
    ['lib/mb/sound/session/midi_input.rb', '((e.time - start) * rate).floor', 'rate is output.sample_rate.round (Integer)'],
  ].freeze

  it 'floors and ceils frame counts from exact products' do
    found = lib_files.flat_map { |f|
      File.readlines(f).filter_map { |l| [rel(f), l.strip] if l.match?(/\*\s*[@\w.]*rate\b[\w.]*\)\.(floor|ceil)\b/) && !l.strip.start_with?('#') }
    }
    bad = unlisted(found, RATE_ALLOWED)
    expect(bad).to eq([]), "frame counts from a product with a rate (check the types; Rational x Float isn't exact):\n#{report(bad)}"
    expect(unused(found, RATE_ALLOWED).map(&:first)).to eq([]), "unused entries: #{unused(found, RATE_ALLOWED)}"
  end

  # `0.5 < -90.db` goes through Decibels#coerce, an Array per comparison
  # (alloc-2: Synth::QUIET_GAIN).  Render paths compare Floats.  A name on
  # the right of a comparison counts if it is a Decibels constant: defined
  # as one in the same file (unqualified), or resolving to one (X::NAME).
  it 'compares no Decibels constant on the right of a comparison' do
    re = /(?<![=!<>])\s(?:<|>|<=|>=)\s+((?:[A-Z]\w*::)*)([A-Z][A-Z0-9_]+)\b/
    found = lib_files.flat_map { |f|
      text = File.read(f)
      own = text.scan(/^\s*([A-Z][A-Z0-9_]*) = -?[\d.]+\.db\b/).flatten
      text.lines.filter_map { |l|
        next if l.strip.start_with?('#')
        hit = l.scan(re).any? { |ns, name|
          if ns.empty?
            own.include?(name)
          else
            v = (Object.const_get("#{ns}#{name}") rescue (MB::Sound.const_get("#{ns}#{name}") rescue nil))
            v.is_a?(MB::Sound::Decibels)
          end
        }
        [rel(f), l.strip] if hit
      }
    }
    expect(found).to eq([]), "Float compared with a Decibels constant (compare with its #to_f, e.g. a Float constant):\n#{report(found)}"
    expect(MB::Sound::Synth::QUIET).to be_a(MB::Sound::Decibels) # (the scan's premise)
    expect(0.6 < -6.db).to eq(false) # (still works, through coerce)
  end

  it 'compares Decibels with numbers without allocating' do
    d = -6.db
    x = d < 0.5
    before = GC.stat(:total_allocated_objects)
    100.times { x = d < 0.5; x = d >= 0.1; x = d * 2.0 }
    # (a splat Array per call before omnibus13: 300)
    expect(GC.stat(:total_allocated_objects) - before).to be < 10
    expect(x).to eq(d.to_f * 2.0)
  end
end
