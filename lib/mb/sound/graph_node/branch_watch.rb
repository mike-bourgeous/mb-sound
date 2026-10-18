module MB
  module Sound
    module GraphNode
      # A validity check for something derived from the branch lists of
      # some Tees (what a sleeping player, skipped voice, or sub-lane keeps
      # reading): current while none of those Tees gained or lost a branch.
      #
      # Before (ux-fix-2), such caches were keyed on Tee.branch_changes,
      # which counts every Tee's branches, so while the scheduler thread
      # built the next scene (making thousands of branches on Tees of the
      # new graphs) every cache was rebuilt every buffer on the render
      # thread: up to 45 ms of a 10.7 ms buffer at night_bus_flow's drop
      # (Linux, no YJIT).  Tee.branch_changes stays the fast path; when it
      # moved, the sum of the watched Tees' versions (each only grows, so
      # the sum moves exactly when one of them does) decides.
      class BranchWatch
        # +tees+ are the Tees whose #branches the cached value read.
        def initialize(tees)
          @tees = tees.uniq(&:__id__).freeze
          @changes = Tee.branch_changes
          @sum = version_sum
        end

        # The Tees watched.
        attr_reader :tees

        # True while no watched Tee gained or lost a branch since #initialize.
        def current?
          changes = Tee.branch_changes
          return true if changes == @changes
          return false unless version_sum == @sum

          @changes = changes
          true
        end

        private

        def version_sum
          sum = 0
          @tees.each { |t| sum += t.branch_version }
          sum
        end
      end
    end
  end
end
