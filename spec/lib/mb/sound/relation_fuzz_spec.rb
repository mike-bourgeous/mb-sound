# Relation fuzzing over small random graphs (spec/support/relation_fuzz.rb):
# planned == unplanned, plan check mode (snapshot/restore), to_ruby and
# graph document round trips, buffer-size invariance within -80 dB.
# Everyday: SEEDS seeds from a fixed base plus a few from RSpec's seed;
# FUZZ=N runs N seeds (the long mode), FUZZ_SEED=n one seed (a repro),
# FUZZ_BASE=n moves the fixed base.
require_relative '../../../support/relation_fuzz'

RSpec.describe('relation fuzzing', :check_shared) do
  seeds =
    if ENV['FUZZ_SEED']
      [Integer(ENV['FUZZ_SEED'])]
    else
      base = Integer(ENV['FUZZ_BASE'] || 1000)
      count = Integer(ENV['FUZZ'] || 30)
      extra = ENV['FUZZ'] ? [] : Array.new(4) { |i| 100_000 + (RSpec.configuration.seed.to_i * 7 + i) % 900_000 }
      (base...(base + count)).to_a + extra
    end

  around do |ex|
    old = [MB::Sound::Plan.enabled, MB::Sound::Plan.precision]
    ex.run
  ensure
    MB::Sound::Plan.enabled, MB::Sound::Plan.precision = old
    MB::Sound.rewind
  end

  it "holds every relation for #{seeds.length} random graphs#{ENV['FUZZ'] ? '' : ' (FUZZ=N for more)'}",
     render_budget: { seconds: 60 + seeds.length * 6, reason: 'each random graph renders 0.1 s about 10 times' } do
    counts = Hash.new(0)
    failures = seeds.flat_map { |s| RelationFuzz.run_seed(s, counts: counts) }
    summary = counts.sort.map { |k, v| "#{k} #{v}" }.join(', ')
    puts "relation fuzz: #{seeds.length} seeds: #{summary}" if ENV['FUZZ'] || ENV['FUZZ_SEED']
    expect(counts[:graphs]).to be >= seeds.length * 0.8, "#{counts[:invalid]} graphs didn't build: #{RelationFuzz.invalid_examples.join("\n")}"
    expect(failures).to eq([]), failures.map(&:to_s).join("\n\n")
  end

  it 'shrinks a failing graph to the parts that fail' do
    big = RelationFuzz::Expr.new(:add, [], [
      RelationFuzz::Expr.new(:softclip, [], [RelationFuzz::Expr.new(:tone, [220, :square, nil], [])]),
      RelationFuzz::Expr.new(:noise, [3], []),
    ])
    stub_const('RelationFuzz::KNOWN', {})
    allow(RelationFuzz).to receive(:check).and_wrap_original { |m, rel, code| code.include?('noise') ? 'fails' : m.call(rel, code) }
    small = RelationFuzz.shrink(big, :buffer_size)
    expect(RelationFuzz.code(small)).to eq('noise(seed: 3).at(0.3)')
  end
end
