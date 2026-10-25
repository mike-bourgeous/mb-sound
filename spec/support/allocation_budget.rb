require 'objspace'

# Counts the Ruby objects (and their bytes) a render path allocates per
# buffer, for render_allocations_spec.rb's budgets (alloc-2, 2026-10-25).
#
#     m = AllocationBudget.measure(buffers: 400) { session.process_buffer }
#     m.objects_per_buffer   # every object Ruby allocated (GC.stat), hidden ones too
#     m.bytes_per_buffer     # ObjectSpace.memsize_of of the traceable ones (Numo data included)
#     m.top(5)               # [["lib/mb/sound/x.rb:12 Numo::SFloat", objects per buffer, bytes per buffer], ...]
#     m.report               # a few lines for failure messages
#
# The window runs with GC off and ObjectSpace.trace_object_allocations on
# (a TracePoint: fine in a spec, never in lib/), then walks the objects of
# that GC generation by allocating file:line and class.  Objects internal
# to the VM or Numo (no source file) count in the totals but not in #top.
# Debug checks that walk graphs on the render path are off meanwhile
# (Session::Strip.structure_check, which spec_helper turns on).
module AllocationBudget
  Result = Struct.new(:buffers, :objects, :bytes, :sites, keyword_init: true) do
    def objects_per_buffer = objects.to_f / buffers
    def bytes_per_buffer = bytes.to_f / buffers

    # The +n+ sites allocating the most objects, per buffer.
    def top(n = 5)
      sites.sort_by { |_, (c, _)| -c }.first(n).map { |k, (c, b)| [k, (c.to_f / buffers).round(2), (b.to_f / buffers).round] }
    end

    def report(n = 8)
      lines = [format('%.1f objects (%.0f bytes) per buffer over %d buffers; top allocators (objects, bytes per buffer):', objects_per_buffer, bytes_per_buffer, buffers)]
      top(n).each { |site, c, b| lines << format('  %7.2f %8d  %s', c, b, site) }
      lines.join("\n")
    end
  end

  # Runs the block +buffers+ times in the measured window (after the
  # caller's warm-up).  Returns a Result.
  def self.measure(buffers:)
    root = File.expand_path('../..', __dir__)
    check = MB::Sound::Session::Strip.structure_check
    MB::Sound::Session::Strip.structure_check = false
    GC.start
    GC.disable
    gen = GC.count
    a0 = GC.stat(:total_allocated_objects)
    ObjectSpace.trace_object_allocations do
      buffers.times { yield }
    end
    objects = GC.stat(:total_allocated_objects) - a0

    sites = Hash.new { |h, k| h[k] = [0, 0] }
    bytes = 0
    ObjectSpace.each_object do |o|
      next unless ObjectSpace.allocation_generation(o) == gen
      file = ObjectSpace.allocation_sourcefile(o) or next
      size = ObjectSpace.memsize_of(o)
      bytes += size
      klass = Kernel.instance_method(:class).bind_call(o)
      key = "#{file.delete_prefix("#{root}/").sub(%r{\A.*/gems/}, 'gem ')}:#{ObjectSpace.allocation_sourceline(o)} #{klass}"
      s = sites[key]
      s[0] += 1
      s[1] += size
    end
    Result.new(buffers: buffers, objects: objects, bytes: bytes, sites: sites)
  ensure
    MB::Sound::Session::Strip.structure_check = check
    ObjectSpace.trace_object_allocations_clear
    GC.enable
  end
end
