# Node traits (node-traits-1, arch-core finding 3): every node kind says what
# running state it keeps, whether it follows the timeline, and how it answers
# "may I sleep now?", on its own class (MB::Sound::NodeTraits), so idle
# skipping (Synth lanes, sub-lanes, drum voices) and Session::Carry ask the
# node instead of keeping class lists that new nodes are missing from (the
# multitap/ping_pong carry cut, research-snapshot-mutability).
#
# The guard: every GraphNode, multi-output, Filter, and timeline class in
# lib/ declares a memory trait (on itself or an ancestor), and its
# declarations agree with what the class does.
RSpec.describe(MB::Sound::NodeTraits, :aggregate_failures) do
  def self.library_classes
    Dir[File.expand_path('../../../../lib/mb/sound/**/*.rb', __dir__)].sort.each { |f| require f }
    g = MB::Sound::GraphNode
    ObjectSpace.each_object(Class).select { |c|
      c.name&.start_with?('MB::Sound::') &&
        (c.include?(g) || c.include?(g::MultiOutput) || c <= MB::Sound::Filter || c.include?(MB::Sound::Sequence::TimelineNode))
    }.reject { |c| c.name.start_with?('MB::Sound::Plan') || c == MB::Sound::Filter }.sort_by(&:name)
  end

  describe 'guard over every node class' do
    classes = library_classes

    it 'finds the node classes' do
      expect(classes.length).to be > 150
      expect(classes).to include(MB::Sound::GraphNode::MultitapDelay, MB::Sound::GraphNode::DelayNetwork, MB::Sound::GraphNode::Reverb, MB::Sound::GraphNode::Chorus::Tail)
    end

    it 'has a memory declaration for every class (on the class or an ancestor)' do
      roots = [MB::Sound::GraphNode, MB::Sound::GraphNode::MultiOutput, MB::Sound::Sequence::TimelineNode]
      missing = classes.reject { |c| (o = described_class.declared_by(c)) && !roots.include?(o) }.map(&:name)
      expect(missing).to eq([]), "declare `node_traits memory: :none | :short | :long` on: #{missing.join(', ')}"
    end

    it 'carries by snapshot only classes that have one, and every class with running state in a snapshot says so' do
      owners = described_class.stateless_snapshot_owners
      classes.each do |c|
        t = c.node_traits
        own = c.method_defined?(:plan_snapshot) && !owners.include?(c.instance_method(:plan_snapshot).owner)
        if t.carry == :snapshot
          expect(own).to eq(true), "#{c} has carry :snapshot without a plan_snapshot of its own"
          expect(c.method_defined?(:plan_restore)).to eq(true), "#{c} has carry :snapshot without plan_restore"
        end
        # (a snapshot of values read from outside, a Constant's or a knob's,
        # is no running state: memory :none)
        expect(t.carry).to eq(:snapshot), "#{c} has a plan_snapshot but carry #{t.carry}" if own && t.memory != :none && c.instance_method(:plan_snapshot).owner != MB::Sound::Filter::SampleWrapper
      end
    end

    it 'gives every timeline node a timeline trait, and only them' do
      tl = MB::Sound::Sequence::TimelineNode
      wrong = classes.select { |c| c.include?(tl) != (c.node_traits.timeline != false) }.map(&:name)
      expect(wrong).to eq([])
    end

    it 'names idle checks the class defines' do
      classes.each do |c|
        m = c.node_traits.idle_check or next
        expect(c.method_defined?(m)).to eq(true), "#{c}'s idle_check #{m} isn't a method of it"
      end
    end

    it 'keeps the long-memory kinds that idle skipping and carries must know about' do
      long = classes.select { |c| c.node_traits.memory == :long }.map(&:name)
      expect(long).to include(
        'MB::Sound::GraphNode::Reverb', 'MB::Sound::GraphNode::MultitapDelay', 'MB::Sound::GraphNode::DelayNetwork',
        'MB::Sound::GraphNode::FeedbackLoop', 'MB::Sound::Filter::Delay', 'MB::Sound::Filter::FIR'
      )
    end
  end

  describe '.of' do
    it 'answers for instances, with wrappers answering for their filter' do
      sig = 100.hz.saw
      delay = sig.delay(0.01)
      lowpass = sig.filter(:lowpass, cutoff: 500, quality: 0.7)
      fir = sig.filter(MB::Sound::Filter::FIR.new({ 0 => 1, 2000 => 1, 3000 => 0, 24000 => 0 }, filter_length: 64))
      expect(described_class.of(delay).memory).to eq(:long)
      expect(described_class.of(delay)).to be_uncarried
      expect(described_class.of(lowpass).memory).to eq(:short)
      expect(described_class.of(lowpass)).to be_snapshot
      expect(described_class.of(fir).memory).to eq(:long)
      expect(described_class.of(1.5)).to eq(described_class::NONE)
    end

    it 'says which nodes block sleeping' do
      reverb = 100.hz.saw.reverb(:hall).outputs[0].graph.find { |n| n.is_a?(MB::Sound::GraphNode::Reverb) }
      expect(described_class.blocks_sleep?(reverb)).to eq(true)
      lfo = 1.beat.hz.lfo
      expect(described_class.blocks_sleep?(lfo)).to eq(false) # (a Tone reading a tempo node...)
      expect(described_class.blocks_sleep?(lfo.graph.find { |n| n.is_a?(MB::Sound::Sequence::TempoNode) })).to eq(true) # (...which follows the timeline)
      expect(described_class.blocks_sleep?(MB::Sound.seq(MB::Sound::C4).loop.notes.stream)).to eq(false)
      expect(described_class.blocks_sleep?(100.hz.saw)).to eq(false)
    end

    it 'checks declarations' do
      k = Class.new { include MB::Sound::GraphNode }
      expect { k.node_traits(memory: :forever) }.to raise_error(ArgumentError, /memory trait must be one of/)
      expect { k.node_traits(sleep: true) }.to raise_error(ArgumentError, /Unknown node traits/)
      expect(k.node_traits.memory).to eq(:short) # (undeclared: short, carried fresh)
      expect(k.node_traits).to be_uncarried
    end
  end
end
