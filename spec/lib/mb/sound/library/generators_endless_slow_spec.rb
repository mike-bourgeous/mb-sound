require 'spec_helper'
require_relative '../../../../support/generator_launch'

# The slow tier of the beat family sweep (generators_endless_spec.rb; in
# its own file since fixes-17, so the everyday file keeps a tight time
# budget): every beat entry steered at 960 BPM, plain at 85 and steered at
# 170 BPM for 65 bars, and on its kit's track too.
RSpec.describe MB::Sound::Library::Generators, 'beat generators keep playing (slow tier)', :aggregate_failures, :slow,
               render_budget: { seconds: 900, reason: 'each beat for 65 bars at 85 and 170 BPM and steered at 960, three launch spellings: about 800 s of audio per beat, mostly the 85 BPM run' } do
  include GeneratorLaunch

  MB::Sound::L.gen.beat.entries.each do |entry|
    it("keeps #{entry.head_path} playing steered, at real tempos, and on its kit's track") { expect_keeps_playing(entry, tier: :slow) }
  end
end
