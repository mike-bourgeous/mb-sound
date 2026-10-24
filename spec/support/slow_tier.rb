# The slow tier inside examples (test-tiers-1, 2026-10-24; see SPEC_SLOW in
# spec_helper.rb).  Exactness sweeps over many buffer sizes keep their
# first +keep+ entries (the reference and one odd split, usually
# [367, 368]) in the everyday run, and run every entry under SLOW=1, so
# each area still runs by default while the long one-sample and
# small-buffer passes wait for the full suite before and after merges.
#
#   slow_tier([[367, 368], [64], [1031], [1]]).each { |s| ... }
#   [[800], *slow_tier([[367, 368], [64]])].each { |s| ... }
module SlowTier
  def slow_tier(list, keep: 1)
    SPEC_SLOW ? list : list.first(keep)
  end
  module_function :slow_tier
end
