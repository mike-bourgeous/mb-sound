require_relative '../sound'

module MB
  module Sound
    # Sound guards (design/notes/sound_guards.md, guards-1, 2026-10-22): the
    # maintainer's "ears win" rule as a check.  A golden set of approved
    # renders across his genres (golden/set.rb) is re-rendered and compared
    # by perceptual fingerprints (Fingerprint: loudness curve, mel
    # spectrum, envelope, onsets, stereo width) committed in
    # golden/fingerprints/, not by md5; the approved renders themselves live
    # outside git (SoundGuard.golden_dir).  A piece that moves past a
    # Comparison threshold fails and lands in a Listening Bench set (approved
    # vs new); approving the new render updates its fingerprint.
    #
    #   bundle exec rake golden:check                 # every piece
    #   bundle exec rake golden:check[techno,dnb]     # some
    #   bundle exec rake golden:approve[techno]       # re-render and approve
    #   bundle exec rake golden:approve[techno] RUN=dir  # approve a check run's render
    #
    # Not loaded by `require 'mb-sound'` (rake tasks and specs require
    # 'mb/sound/sound_guard').
    module SoundGuard
    end
  end
end

require_relative 'sound_guard/fingerprint'
require_relative 'sound_guard/comparison'
require_relative 'sound_guard/golden_set'
require_relative 'sound_guard/runner'
