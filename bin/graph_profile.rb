#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures the graph cost of a bin/ script (effect, synth, or song) as a
# percentage of realtime at one or more buffer sizes, and optionally the
# self time of each node class.  The script runs normally up to the point
# where it would play, then its graph is captured instead (effects and
# synths through ScriptRunner; songs through MB::Sound.bg, taking the
# players launched immediately).  Only the graph is measured: no Session
# mixing, master effects, or output.
#
# --profile wraps every node's #sample, which adds about 3 us per call, so
# cheap nodes called often (Constant, Tee branches) look more expensive than
# they are; compare self times between branches rather than reading them as
# absolute costs, and use the unprofiled percentages for speedups.  It also
# lists self allocations per call (exact: the wrapper allocates nothing).
#
# GC and allocations: every run reports GC.stat deltas over the measured
# buffers (GC runs, minor/major, GC time as a share of the render's CPU
# time, objects allocated per buffer), the longest single GC
# (GC::Profiler's GC_TIME, marking plus its lazy sweep steps, so an upper
# bound on one pause), thread CPU time per buffer for buffers without GC
# work (median, 99th percentile), buffers in which a GC started (median,
# max; the difference from the no-GC median is about the pause), and
# buffers that only ran incremental marking or lazy sweep steps (max),
# and why GCs ran
# (minor:newobj = object slots ran out, minor:malloc = malloc'd bytes such
# as Numo data passed a limit, major:oldgen/nofree/oldmalloc/...).  The run
# starts after a warm-up (at least 12000 samples, for YJIT) and a GC.start,
# so it shows the graph's steady state, not GC left over from loading.
# -a N traces 100 more buffers with GC disabled and lists the N Ruby lines
# that allocated the most objects per buffer, with bytes
# (ObjectSpace.memsize_of; Numo arrays include their data) and classes.
#
# Fused plans (MB::Sound::Plan) are on as when playing (Synth lanes plan
# themselves; the captured graph is planned as Session#add would); --plan
# off measures the unfused graph, --plan both alternates off and on runs
# (--rounds of each, best of each reported), and each run lists its
# regions and how many blocks ran planned.  For worst-case (modulated)
# synth costs use spec/test_data/dense_modulated.mid (8 busy voices,
# controllers and bend moving every 10 ms).
#
# Graphs that take an input (effects) get spec/test_data/arp_a7.flac unless
# script arguments name another file; synths need a MIDI file argument.
#
# Usage: $0 [options] script.rb [script arguments...]
#
# Examples:
#     $0 bin/effects/flanger.rb
#     $0 -n 32,128,800 --profile bin/effects/tape_delay.rb
#     $0 bin/synths/fm_bass.rb spec/test_data/midi.mid
#     $0 -s 2 bin/songs/stereo_drone.rb
#     $0 -n 128 -a 10 bin/effects/flanger.rb     # top 10 allocation sites
#     $0 -n 128,512 --plan both bin/synths/fm_bass.rb spec/test_data/dense_modulated.mid
#
# Compare branches by running the same command in each worktree, in
# alternating order (other work on the machine skews single runs).

require 'bundler/setup'
require 'mb-sound'

# Captures graphs instead of playing them.
module GraphCapture
  class Captured < StandardError
    attr_reader :graph

    def initialize(graph)
      @graph = graph
      super('captured')
    end
  end

  @songs = []

  class << self
    attr_reader :songs
  end

  module RunnerHook
    def play_or_render(graph)
      raise Captured.new(graph)
    end
  end
  MB::Sound::ScriptRunner.prepend(RunnerHook)

  module BgHook
    def bg(name = nil, graph = nil, **kwargs, &block)
      graph = name if graph.nil? && !name.is_a?(Symbol) && !name.is_a?(String)
      GraphCapture.songs << graph if graph
      nil
    end
  end
end

# Accumulates self time and self allocations per node class (see
# --profile).  The wrapper allocates nothing itself, so allocation counts
# are the node's own (children's allocations subtracted like their time).
module SelfTime
  @totals = Hash.new(0.0)
  @calls = Hash.new(0)
  @allocs = Hash.new(0)
  @stack = []
  @alloc_stack = []

  class << self
    attr_reader :totals, :calls, :allocs, :stack, :alloc_stack

    def wrap(node)
      return if node.instance_variable_get(:@__self_time_class)

      node.instance_variable_set(:@__self_time_class, node.class.name.sub(/\AMB::Sound::/, ''))
      node.singleton_class.prepend(Wrapper)
    end

    def reset
      @totals.clear
      @calls.clear
      @allocs.clear
    end
  end

  # Prepended to each profiled node's singleton class.  Uses (...) rather
  # than *args so the wrapper doesn't allocate an Array per call.
  module Wrapper
    def sample(...)
      stack = SelfTime.stack
      alloc_stack = SelfTime.alloc_stack
      t0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
      a0 = GC.stat(:total_allocated_objects)
      stack.push(0.0)
      alloc_stack.push(0)
      begin
        super(...)
      ensure
        children = stack.pop
        child_allocs = alloc_stack.pop
        elapsed = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t0
        allocated = GC.stat(:total_allocated_objects) - a0
        klass = @__self_time_class
        SelfTime.totals[klass] += elapsed - children
        SelfTime.allocs[klass] += allocated - child_allocs
        SelfTime.calls[klass] += 1
        stack[-1] += elapsed unless stack.empty?
        alloc_stack[-1] += allocated unless alloc_stack.empty?
      end
    end
  end
end

# GC and allocation statistics for one measured run: GC.stat deltas, plus
# CPU time per buffer to compare buffers that did GC work (a GC started, or
# incremental marking or lazy sweeping was under way) with the others.
class GCStats
  KEYS = [:count, :minor_gc_count, :major_gc_count, :total_allocated_objects, :time, :old_objects, :heap_live_slots].freeze

  attr_reader :buffer_times, :buffer_gcs

  def initialize(frames)
    @buffer_times = Array.new(frames, 0.0)
    @buffer_gcs = Array.new(frames, 0)
  end

  def start
    GC::Profiler.clear
    GC::Profiler.enable
    @before = GC.stat.slice(*KEYS)
  end

  def stop(buffers)
    @after = GC.stat.slice(*KEYS)
    # GC_TIME covers a GC's marking plus its lazy sweep steps, so it is an
    # upper bound on any single pause it caused
    raw = GC::Profiler.raw_data
    @gc_times = raw.map { |r| r[:GC_TIME] }
    # Why each GC ran: e.g. newobj (object slots ran out) or malloc (malloc'd
    # bytes, such as Numo array data, passed a limit); major_by for majors
    @reasons = raw.map { |r|
      f = r[:GC_FLAGS] || {}
      f[:major_by] ? "major:#{f[:major_by]}" : "minor:#{f[:gc_by]}"
    }.tally
    GC::Profiler.disable
    GC::Profiler.clear
    @buffers = buffers
    @buffer_times = @buffer_times.first(buffers)
    @buffer_gcs = @buffer_gcs.first(buffers)
  end

  def delta(key)
    @after[key] - @before[key]
  end

  def allocations_per_buffer
    delta(:total_allocated_objects).to_f / @buffers
  end

  # GC time in seconds (GC.stat(:time) is whole milliseconds, accumulated
  # from nanoseconds, so over a run it is accurate to 1 ms).
  def gc_seconds
    delta(:time) / 1000.0
  end

  def longest_gc
    @gc_times.max || 0.0
  end

  # CPU times of buffers in which a GC started, buffers that only did
  # incremental marking or lazy sweeping, and buffers without GC work.
  def buffer_groups
    groups = { start: [], step: [], none: [] }
    @buffer_times.each_with_index do |t, i|
      groups[[:none, :step, :start][@buffer_gcs[i]]] << t
    end
    groups.transform_values(&:sort)
  end

  def self.percentile(sorted, fraction)
    return 0.0 if sorted.empty?

    sorted[(sorted.size * fraction).floor.clamp(0, sorted.size - 1)]
  end

  def report(elapsed, buffer_seconds)
    g = buffer_groups
    pc = ->(list, f) { GCStats.percentile(list, f) * 1000 }
    lines = []
    lines << format('    GC: %d runs (%d minor, %d major), %.1f ms = %.2f%% of render time; %.1f objects/buffer; longest GC %.2f ms',
      delta(:count), delta(:minor_gc_count), delta(:major_gc_count),
      gc_seconds * 1000, 100 * gc_seconds / elapsed, allocations_per_buffer, longest_gc * 1000)
    lines << format('    buffer CPU (ms, buffer is %.2f): no GC median %.2f p99 %.2f (%d); GC start median %.2f max %.2f (%d); GC steps max %.2f (%d)',
      buffer_seconds * 1000, pc.(g[:none], 0.5), pc.(g[:none], 0.99), g[:none].size,
      pc.(g[:start], 0.5), pc.(g[:start], 1), g[:start].size, pc.(g[:step], 1), g[:step].size)
    lines << format('    heap: old objects %+d, live slots %+d (growth means retained objects, which lead to major GCs)',
      delta(:old_objects), delta(:heap_live_slots))
    lines << "    GC causes: #{@reasons.sort.map { |r, c| "#{r} #{c}" }.join(', ')}" unless @reasons.empty?
    lines
  end
end

# Lists where a run allocates objects: traces a few buffers with GC
# disabled (so every object survives to be counted), grouped by the Ruby
# line that allocated it; bytes are ObjectSpace.memsize_of (Numo arrays
# include their data).
module AllocationSites
  ROOT = File.expand_path('..', __dir__) + '/'

  def self.trace(outputs, n, buffers)
    require 'objspace'

    GC.start
    GC.disable
    ObjectSpace.trace_object_allocations_start
    buffers.times do
      ended = false
      outputs.each { |o| ended = true if o.sample(n).nil? }
      break if ended
    end
    ObjectSpace.trace_object_allocations_stop

    sites = Hash.new { |h, k| h[k] = [0, 0, Hash.new(0)] }
    ObjectSpace.each_object do |obj|
      file = ObjectSpace.allocation_sourcefile(obj)
      next unless file

      site = sites["#{short_path(file)}:#{ObjectSpace.allocation_sourceline(obj)}"]
      site[0] += 1
      site[1] += ObjectSpace.memsize_of(obj)
      site[2][class_name(obj)] += 1
    end
    sites
  ensure
    ObjectSpace.trace_object_allocations_clear
    GC.enable
  end

  def self.short_path(file)
    return file.delete_prefix(ROOT) if file.start_with?(ROOT)

    file.sub(%r{\A.*/gems/}, '')
  end

  def self.class_name(obj)
    klass = ObjectSpace.internal_class_of(obj) rescue nil
    name = (klass.respond_to?(:name) && klass.name) || klass.to_s
    name.sub(/\AMB::Sound::/, '')
  rescue StandardError
    '?'
  end

  def self.report(sites, buffers, top)
    total_objects = sites.sum { |_, v| v[0] }
    total_bytes = sites.sum { |_, v| v[1] }
    lines = [format('    allocation sites (%d traced buffers): %.1f objects, %.0f bytes per buffer',
      buffers, total_objects.to_f / buffers, total_bytes.to_f / buffers)]
    sites.sort_by { |_, v| -v[0] }.first(top).each do |site, (count, bytes, classes)|
      kinds = classes.sort_by { |_, c| -c }.first(3).map { |k, c| "#{k} #{format('%.3g', c.to_f / buffers)}" }.join(', ')
      lines << format('      %7.2f obj %8.0f B  %-58s %s', count.to_f / buffers, bytes.to_f / buffers, site, kinds)
    end
    lines
  end
end

def capture_graph(script, args)
  ARGV.replace(args)
  $0 = script
  graph = nil

  MB::Sound.singleton_class.prepend(GraphCapture::BgHook) unless MB::Sound.singleton_class.include?(GraphCapture::BgHook)
  GraphCapture.songs.clear
  begin
    load script
  rescue GraphCapture::Captured => e
    graph = e.graph
  end

  if graph.nil?
    songs = GraphCapture.songs
    raise "#{script} produced no graph (is it an effect, synth, or song script?)" if songs.empty?

    graph = songs.size == 1 ? songs.first : songs
  end

  graph
end

# Every output channel to sample each buffer.
def outputs_of(graph)
  list = graph.is_a?(Array) ? graph : [graph]
  list.flat_map { |g| g.respond_to?(:outputs) ? g.outputs.to_a : [g] }
end

# Every node feeding the outputs (for --profile).
def nodes_of(outputs)
  outputs.flat_map { |o| o.respond_to?(:graph) ? o.graph(include_tees: true) : [o] }.uniq
end

# Regions of fused plans (see MB::Sound::Plan) in the graphs feeding
# +outputs+.
def plan_regions(outputs)
  nodes_of(outputs).filter_map { |n| n.instance_variable_get(:@plan_region) }.uniq
end

# Captures the script's graph with plans in +mode+ (:on, :off, or :ruby)
# and installs plans on it as a Session would.
def capture_with_plans(script, args, mode)
  MB::Sound::Plan.enabled = mode != :off
  MB::Sound::Plan.engine = mode == :ruby ? :ruby : :c
  graph = capture_graph(script, args)
  outputs = outputs_of(graph)
  MB::Sound::Plan.install(outputs) if mode != :off
  outputs
end

# Measures one run of +outputs+ at +n+ samples per buffer; prints the
# report and returns the percentage of realtime.
def measure(script, outputs, n, p, label)
  SelfTime.reset

  # Warm up (YJIT compiles methods after many calls), then start from a
  # clean heap so a major GC left over from loading the script isn't
  # counted as the graph's
  [10, 12000 / n].max.times { outputs.each { |o| o.sample(n) } }

  # Profile after the warm-up so plans are built: nodes inside fused
  # regions never run, and a region's root reports the region's time
  if p.profile
    regions = plan_regions(outputs)
    members = regions.flat_map { |r| r.members - [r.root] }.to_h { |m| [m, true] }.compare_by_identity
    nodes_of(outputs).each do |node|
      next unless node.respond_to?(:sample) && !node.frozen? && !members.key?(node)

      SelfTime.wrap(node)
      if (r = node.instance_variable_get(:@plan_region))
        node.instance_variable_set(:@__self_time_class, "Plan region (#{r.members.length} nodes, root #{node.class.name.sub(/\AMB::Sound::/, '')})")
      end
    end
  end

  GC.start
  frames = (p.seconds * 48000 / n).ceil
  gc = GCStats.new(frames)
  times = gc.buffer_times
  gcs = gc.buffer_gcs

  # The loop allocates nothing itself, so allocation counts are the graph's
  gc.start
  t0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  done = frames
  frames.times do |i|
    ended = false
    count0 = GC.count
    busy = GC.latest_gc_info(:state) != :none
    b0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    outputs.each { |o| ended = true if o.sample(n).nil? }
    times[i] = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - b0
    # A buffer did GC work if a GC started or an incremental mark or lazy
    # sweep was running at either end
    gcs[i] = GC.count != count0 ? 2 : (busy || GC.latest_gc_info(:state) != :none) ? 1 : 0
    if ended
      done = i
      break
    end
  end
  elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t0
  gc.stop([done, 1].max)
  played = done * n / 48000.0
  percent = 100 * elapsed / played

  puts format('%-40s buffer %5d: %7.1f%% of realtime (%d outputs, %.1f s%s%s)',
    File.basename(script), n, percent, outputs.size, played, p.profile ? ', profiled' : '', label)
  puts gc.report(elapsed, n / 48000.0)

  regions = plan_regions(outputs)
  unless regions.empty?
    planned = regions.sum(&:planned_blocks)
    unfused = regions.sum(&:unfused_blocks)
    ops = regions.sum { |r| r.program ? r.program.ops.length : 0 }
    puts format('    plans: %d regions covering %d nodes (%d ops); %d blocks planned, %d unfused',
      regions.length, regions.sum { |r| r.members.length }, ops, planned, unfused)
  end

  if p.profile
    total = SelfTime.totals.values.sum
    SelfTime.totals.sort_by { |_, t| -t }.first(12).each do |klass, t|
      calls = SelfTime.calls[klass]
      puts format('    %-44s %5.1f%%  %8.2f us/call  %8d calls  %6.2f obj/call',
        klass, 100 * t / total, t / calls * 1e6, calls, SelfTime.allocs[klass].to_f / calls)
    end

    allocating = SelfTime.allocs.select { |_, a| a > 0 }.sort_by { |_, a| -a }.first(8)
    unless allocating.empty?
      puts '    most allocations (self, per buffer):'
      allocating.each do |klass, a|
        puts format('      %-44s %8.2f obj/buffer', klass, a.to_f / done.clamp(1..))
      end
    end
  end

  if p.allocations > 0
    traced = 100
    sites = AllocationSites.trace(outputs, n, traced)
    puts AllocationSites.report(sites, traced, p.allocations)
  end

  percent
end

MB::Sound.script(
  args: 1..,
  buffer: ['800', String, 'Comma-separated buffer sizes', '-n'],
  seconds: [4.0, '-s', 'Seconds of audio per buffer size', 0.1..],
  profile: [false, 'Also report self time and self allocations per node class (slower; shares are what matter; a fused region reports as one "Plan region")'],
  allocations: [0, Integer, '-a', 'Also list the top N allocation sites per buffer (traces 100 more buffers with GC off)', 0..],
  plan: ['on', String, 'Fused plans (MB::Sound::Plan): on, off, ruby (the Ruby mirror), or both (alternating off and on runs, best of --rounds)', '-p', ['on', 'off', 'ruby', 'both']],
  rounds: [3, Integer, '-r', 'Runs of each mode with --plan both', 1..],
) { |args, p|
  script, *script_args = args
  sizes = p.buffer.split(',').map { |v| Integer(v) }

  script_args << '-q' unless script_args.include?('-q') # don't print the script's parameters

  # Effects get the short test file unless an audio file was given
  if File.read(script).include?('effect_script') && script_args.none? { |a| a.match?(/\.(flac|wav|mp3|ogg)\z/i) }
    script_args << File.expand_path('../spec/test_data/arp_a7.flac', __dir__)
  end

  modes = p.plan == 'both' ? [:off, :on] * p.rounds : [p.plan.to_sym]

  sizes.each do |n|
    results = Hash.new { |h, k| h[k] = [] }
    modes.each do |mode|
      outputs = capture_with_plans(script, script_args.dup, mode)
      results[mode] << measure(script, outputs, n, p, mode == :on ? '' : ", plans #{mode}")
    end

    if p.plan == 'both'
      off = results[:off].min
      on = results[:on].min
      puts format('%-40s buffer %5d: best of %d: plans off %.1f%%, on %.1f%% of realtime (%+.1f%%)',
        File.basename(script), n, p.rounds, off, on, 100 * (on - off) / off)
    end
  end
}
