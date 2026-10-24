# Helpers for the buffer size invariance specs
# (spec/lib/mb/sound/buffer_size_invariance*_spec.rb): render a node at
# several buffer sizes and expect the same samples as at 800.
module BufferSizeHelpers
  SIZES = [[367, 368], [64], [1031]].freeze

  # Renders the node from +make+ for +seconds+ in buffers cycling through
  # +sizes+ (seeded and rewound, so every render builds the same graph).
  def render_sizes(make, sizes, seconds)
    MB::Sound.rewind
    MB::Sound.seed(1)
    node = make.call
    total = (seconds * 48000).round
    out = nil
    n = 0
    i = 0
    while n < total
      c = [sizes[i % sizes.length], total - n].min
      b = node.sample(c)
      break if b.nil?

      out ||= b.class.zeros(total)
      out[n...(n + b.length)] = b
      n += c
      i += 1
    end
    [out, node]
  ensure
    MB::Sound.rewind
  end

  include SlowTier

  # Expects the same samples at every size in +sizes+ as at 800 (only the
  # first size outside the slow tier, SLOW=1; see support/slow_tier.rb).
  # +one_sample_seconds+ shortens the one-sample-buffer render ([1], about
  # 70 us per buffer for a small Synth: 3 s took 12 s) to its first
  # seconds, compared against the start of the reference.
  def expect_invariant(make, seconds: 2.1, sizes: SIZES, tolerance: 0, one_sample_seconds: nil)
    ref, node = render_sizes(make, [800], seconds)
    expect(ref.abs.max).to be > 0.01
    slow_tier(sizes).each do |s|
      out, _ = render_sizes(make, s, s == [1] && one_sample_seconds ? [one_sample_seconds, seconds].min : seconds)
      r = ref[0...out.length]
      if tolerance == 0
        diff = (out - r).ne(0).where.to_a
        expect(diff.first(5)).to eq([]), "at buffer sizes #{s}: #{diff.length} samples differ from 800, first #{diff.first.inspect}"
      else
        expect((out - r).abs.max).to be <= tolerance * r.abs.max, "at buffer sizes #{s}"
      end
    end
    node
  end
end
