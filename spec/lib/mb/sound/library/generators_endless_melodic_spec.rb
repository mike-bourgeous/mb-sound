require 'spec_helper'
require_relative '../../../../support/generator_launch'

# The melodic L.gen entries keep playing on a track and with no track (the
# family sweep of beat-halftime-1; the regression and the drum beats:
# generators_endless_spec.rb; the slow tier's longer runs:
# generators_endless_melodic_slow_spec.rb).
RSpec.describe MB::Sound::Library::Generators, 'melodic generators keep playing', :aggregate_failures do
  include GeneratorLaunch

  MB::Sound::L.gen.entries.reject { |e| e.family == :beat }.each do |entry|
    it("keeps #{entry.head_path} playing on a track and with no track") { expect_keeps_playing(entry) }
  end
end
