# Metadata never acts as data (metadata-2): every graph sweep factory
# (spec/support/graph_sweep.rb), built again with metadata that looks like
# data on every node it has, inner ones too (GraphSweep.meta_everywhere:
# option names, structural words, code, terminal escapes, deep nesting),
# renders the same samples bit for bit, unplanned and planned, with the
# same plan, and allocates the same while rendering.  The relation fuzz's
# :meta relation (spec/support/relation_fuzz.rb) and the session fuzz's
# `meta` command check the same for random graphs and songs, with the
# round trips.
require_relative '../../../support/graph_sweep'

RSpec.describe('metadata invariance', :aggregate_failures) do
  around do |ex|
    old = MB::Sound::Plan.enabled
    ex.run
  ensure
    MB::Sound::Plan.enabled = old
    MB::Sound.rewind
  end

  def build(factory, meta:)
    MB::Sound.rewind
    MB::Sound.seed(1)
    Numo::NArray.srand(1)
    g = factory.call(GraphSweep::Context.new)
    meta ? GraphSweep.meta_everywhere(g) : g
  end

  # The graph's samples over a few buffer sizes (binary), and with
  # +planned+ its plan's regions (member classes).
  def render(g, planned)
    inst = planned ? MB::Sound::Plan.install(g) : nil
    regions = inst ? inst.regions.map { |r| r.members.map { |m| m.class.name } } : []
    outs = g.respond_to?(:outputs) ? g.outputs.to_a : [g]
    bufs = outs.map { [] }
    [800, 367, 1, 800].each do |n|
      outs.each_with_index do |o, i|
        b = o.sample(n)
        bufs[i] << (b.nil? ? '' : b.to_binary)
      end
    end
    [bufs.map(&:join), regions]
  end

  factories = GraphSweep.factories.reject { |name, _| GraphSweep::PERFORMANCE_STATE.key?(name) || name.start_with?('BusTap', 'capture tap') }

  [false, true].each do |planned|
    it "changes no sample of #{factories.length} sweep graphs#{planned ? ', planned, and no plan region' : ', unplanned'}" do
      differ = []
      MB::Sound::Plan.enabled = planned
      factories.each do |name, factory|
        a, ra = render(build(factory, meta: false), planned)
        b, rb = render(build(factory, meta: true), planned)
        differ << name unless a == b
        differ << "#{name} (plan regions)" unless ra == rb
      rescue StandardError => e
        differ << "#{name}: #{e.class}: #{e.message.lines.first}"
      end
      expect(differ).to eq([])
    end
  end

  it 'allocates the same while rendering' do
    factory = GraphSweep.factories.find { |n, _| n.start_with?('metadata on every node') }[1]
    # (the first build warms process-wide caches: counted apart)
    counts = [false, false, true, false, true].map do |meta|
      g = build(factory, meta: meta)
      outs = g.outputs.to_a
      4.times { outs.each { |o| o.sample(128) } } # (warm up)
      GC.disable
      before = GC.stat(:total_allocated_objects)
      20.times { outs.each { |o| o.sample(128) } }
      GC.stat(:total_allocated_objects) - before
    ensure
      GC.enable
    end
    expect(counts.drop(1).uniq.length).to eq(1), "objects allocated in 20 buffers, without and with metadata (the first a warm-up): #{counts.inspect}"
  end
end
