require 'spec_helper'
require_relative '../../../../support/generator_launch'

# The slow tier of the melodic family sweep
# (generators_endless_melodic_spec.rb; in its own file since fixes-17, so
# the everyday file keeps a tight time budget): every melodic entry
# steered at 960 BPM, plain at 85 and steered at 170 BPM for 65 bars.
RSpec.describe MB::Sound::Library::Generators, 'melodic generators keep playing (slow tier)', :aggregate_failures, :slow,
               render_budget: { seconds: 1500, reason: 'each melodic entry for 65 bars at 85 and 170 BPM and steered at 960, two launch spellings' } do
  include GeneratorLaunch

  MB::Sound::L.gen.entries.reject { |e| e.family == :beat }.each do |entry|
    it("keeps #{entry.head_path} playing steered and at real tempos") { expect_keeps_playing(entry, tier: :slow) }
  end
end
