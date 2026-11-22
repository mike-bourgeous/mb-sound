require 'spec_helper'
require_relative '../../../../support/generator_launch'

# The melodic L.gen entries keep playing on a track and with no track (the
# family sweep of beat-halftime-1; the regression and the drum beats:
# generators_endless_spec.rb).
RSpec.describe MB::Sound::Library::Generators, 'melodic generators keep playing', :aggregate_failures,
               render_budget: { seconds: 1500, reason: 'each melodic entry for 40 bars (65 in the slow tier), two launch spellings; fast tempos keep it ~10 s of audio each' } do
  include GeneratorLaunch

  GeneratorLaunch.sweep(self, MB::Sound::L.gen.entries.reject { |e| e.family == :beat })
end
