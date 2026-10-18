require_relative '../../../../support/graph_sweep'

# ux-fix-1 item 1: the default #inspect printed every instance variable
# (2,000,000 characters for a delay; Pry opened a pager).  Every node in the
# graph sweep's graphs, sampled or not, inspects as one short line.
RSpec.describe(MB::Sound::GraphNode::Inspect) do
  limit = MB::Sound::GraphNode::Inspect::INSPECT_LIMIT

  it 'prints a node as its type and the Ruby that builds it' do
    node = 261.63.hz.saw.delay(0.125, feedback: 0.4)
    expect(node.inspect).to match(/\A#<SampleWrapper 261\.63\.hz\.saw\.delay\(0\.125, feedback: 0\.4\)>\z/)
  end

  it 'prints the same line through pp (Pry uses it)' do
    node = 220.hz.saw.lp4(800)
    expect(PP.pp(node, +'').chomp).to eq(node.inspect)
  end

  it 'keeps the old dump in #inspect_full' do
    expect(220.hz.saw.inspect_full).to include('@')
  end

  it 'caps long graphs at the limit' do
    node = (1..40).map { |i| (100 + i).hz.saw }.sum
    expect(node.inspect.length).to be <= limit
    expect(node.inspect).to end_with('...>')
  end

  it 'joins multi-line code onto one line' do
    s = MB::Sound.seq(MB::Sound::C4).n8.synth { |v| v.tone.saw * v.env }
    expect(s.inspect).to eq('#<Synth seq(C4).n8.synth { |v| v.hz.saw * v.env }>')
  end

  it 'summarizes Notes and Sessions' do
    expect(MB::Sound.seq(MB::Sound::C4).notes.inspect).to eq('#<Notes seq(C4).notes>')
    session = MB::Sound::Session.new(realtime: false)
    expect(session.inspect).to match(/\A#<Session render, 0 players, 120 bpm>\z/)
  ensure
    session&.close
  end

  it 'inspects every node of every graph sweep graph in one short line' do
    seen = 0
    GraphSweep.factories.each do |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      nodes = graph.respond_to?(:graph) ? graph.graph : [graph]
      ([graph] + nodes).each do |n|
        text = n.inspect
        seen += 1
        expect(text.length).to be <= limit + 40, "#{name}: #{n.class} inspects as #{text.length} characters: #{text[0, 300]}"
        expect(text).not_to include("\n"), "#{name}: #{n.class} inspects on several lines"
      end
    end
    expect(seen).to be > 200
  end

  # ux-fix-2: ProcNodes were named after their block's source location, and
  # names are shown as values, so `play C4.saw` printed
  # `freq=/.../lib/mb/sound/tuning.rb:87`.  Descriptions shown to users
  # (to_s, inspect, play/players descriptions) never hold file locations.
  it 'never shows a source location in any graph sweep node\'s descriptions' do
    location = /\.rb:\d+|#{Regexp.escape(MB::Sound::GraphNode::ProcNode::ROOT)}/
    seen = 0
    GraphSweep.factories.each do |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      nodes = graph.respond_to?(:graph) ? graph.graph : [graph]
      texts = ([graph] + nodes).flat_map { |n| [n.to_s, n.inspect] }
      texts << MB::Sound::Playable.describe(graph)
      texts.each do |text|
        seen += 1
        expect(text).not_to match(location), "#{name}: #{text[0, 300]}"
      end
    end
    expect(seen).to be > 400

    expect(MB::Sound::C4.saw.to_s).to match(/ freq=C4 /)
    expect(MB::Sound::C4.saw.fm(MB::Sound::C5.sine.at(100)).to_s).to match(/ freq=\(C4 \+ /)
  end
end
