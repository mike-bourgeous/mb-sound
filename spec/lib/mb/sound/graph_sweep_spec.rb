# "Memcheck light": every GraphNode type, every filter type, in small
# graphs with modulated inputs, MIDI events, stereo bundles, and feedback
# loops, run planned and unplanned (MB::Sound::Plan) at buffer sizes 1, 128,
# and 800.  In the normal suite it checks for exceptions and non-finite
# output; under Valgrind (every `rake memcheck:changed` run includes it, see
# MemcheckSelection::ALWAYS) it reaches C paths that the per-extension specs
# may not combine.
#
# FACTORIES builds one representative graph per entry from a context with
# modulated sources and short clips.  Filter entries are generated from the
# filters' own type lists (Filter::SVF::FILTER_TYPES, Cookbook::FILTER_TYPES,
# FourPole::MODES / DRIVE_MODES), so new types are swept automatically.
# Filters are plan ops (SVF, cookbook biquad, four-pole; 2026-10-10), so
# the planned variant covers their fused regions; an example checks every
# filter entry is fused.
#
# The guard records every GraphNode, multi-output, and Filter class
# constructed while building the factories, and requires every such class
# in lib/ to be built by some factory or listed in EXEMPT with a reason.
require_relative '../../../support/graph_sweep'

RSpec.describe('graph sweep (memcheck light)', :check_shared) do
  around(:each) do |example|
    old = MB::Sound::Plan.enabled
    example.run
  ensure
    MB::Sound::Plan.enabled = old
  end

  names = GraphSweep.factories.map(&:first)
  it 'has unique factory names' do
    expect(names.length).to eq(names.uniq.length)
  end

  GraphSweep.factories.each do |name, factory|
    it "runs #{name} planned and unplanned at every buffer size" do
      [true, false].each do |planned|
        GraphSweep::SIZES.each do |size, buffers|
          MB::Sound::Plan.enabled = planned
          MB::Sound.seed(1)
          graph = factory.call(GraphSweep::Context.new)
          MB::Sound::Plan.install(graph) if planned
          begin
            GraphSweep.run(graph, size, buffers)
          rescue => e
            raise e.class, "#{name} (#{planned ? 'planned' : 'unplanned'}, #{size}-sample buffers): #{e.message}", e.backtrace
          end
        end
      end
    end
  end

  # Filters are plan ops (2026-10-10): the planned variant above runs them
  # fused.  This keeps it that way: every SVF, cookbook biquad, and
  # four-pole entry (outside feedback loops) has its filter node in a
  # region when planned.
  it 'fuses every filter entry in the planned variant' do
    MB::Sound::Plan.enabled = true
    filters = GraphSweep.factories.select { |name, _| name.start_with?('filter(:', 'lp4', 'diode') }
    expect(filters.length).to be > 40
    unfused = filters.reject { |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      inst = MB::Sound::Plan.install(graph)
      members = inst ? inst.regions.flat_map(&:members) : []
      members.any? { |m| m.is_a?(MB::Sound::Filter::SampleWrapper) || m.is_a?(MB::Sound::GraphNode::FourPole) }
    }.map(&:first)
    expect(unfused).to eq([])
  end

  describe 'coverage guard' do
    def library_classes
      LibraryFiles.require_all
      g = MB::Sound::GraphNode
      ObjectSpace.each_object(Class).select { |c|
        c.name&.start_with?('MB::Sound::') && (c.include?(g) || c.include?(g::MultiOutput) || c <= MB::Sound::Filter)
      }.reject { |c| c.name.start_with?('MB::Sound::Plan') || c == MB::Sound::Filter }
    end

    it 'builds every GraphNode, multi-output, and Filter class, or lists it in EXEMPT' do
      built = Set.new
      # Ruby 4's opt_new skips the Class#new call event, so watch initialize
      tp = TracePoint.new(:call, :c_call) { |t| built << t.self.class if t.method_id == :initialize }
      tp.enable do
        GraphSweep.factories.each do |_name, factory|
          MB::Sound.seed(1)
          g = factory.call(GraphSweep::Context.new)
          GraphSweep.run(g, 64, 1)
        end
      end

      # An abstract base counts as built when a subclass is
      covered = ->(c) { built.any? { |b| b <= c } }
      missing = library_classes.reject { |c| covered.(c) || GraphSweep::EXEMPT.key?(c.name) }.map(&:name).sort
      expect(missing).to eq([])

      names = library_classes.map(&:name)
      expect(GraphSweep::EXEMPT.keys - names).to eq([]) # EXEMPT names classes that no longer exist
      stale = library_classes.select { |c| GraphSweep::EXEMPT.key?(c.name) && covered.(c) }.map(&:name)
      expect(stale).to eq([]) # EXEMPT lists classes the sweep builds
    end
  end
end
