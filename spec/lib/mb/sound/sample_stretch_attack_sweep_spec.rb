# The stretch attack sweep (spec/support/stretch_attack_sweep.rb): seeded
# synthetic loops (note changes, a cut into the loop point, hits over a
# bass) whose attacks spectral stretches must keep, looped and not.
# Everyday: the seeds that failed before their fix and one seed of each
# kind; FUZZ=N runs N seeds from FUZZ_BASE (1000), FUZZ_SEED=n one seed.
require_relative '../../../support/stretch_attack_sweep'

RSpec.describe(MB::Sound::Sample::Spectral, 'stretch attack sweep') do
  seeds =
    if ENV['FUZZ_SEED']
      [Integer(ENV['FUZZ_SEED'])]
    elsif ENV['FUZZ']
      base = Integer(ENV['FUZZ_BASE'] || 1000)
      (base...(base + Integer(ENV['FUZZ']))).to_a
    else
      (StretchAttackSweep::FOUND + (1000...(1000 + StretchAttackSweep::KINDS.length)).to_a).uniq
    end

  seeds.each do |seed|
    it "keeps the attacks of seed #{seed}" do
      c = StretchAttackSweep.build(seed)
      skip StretchAttackSweep::KNOWN[seed] if StretchAttackSweep::KNOWN.key?(seed)

      bad = StretchAttackSweep.check(c)
      expect(bad).to eq([]), StretchAttackSweep.report(c, bad)
    end
  end
end
