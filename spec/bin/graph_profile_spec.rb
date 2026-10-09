require 'shellwords'

RSpec.describe('bin/graph_profile.rb') do
  it 'reports cost, GC, per-class allocations, and allocation sites' do
    text = `bin/graph_profile.rb -n 128 -s 0.5 --profile -a 5 bin/effects/flanger.rb 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/flanger\.rb +buffer +128: +[\d.]+% of realtime \(2 outputs, 0\.5 s, profiled\)/)

    # GC.stat deltas: the flanger allocates objects every buffer
    gc = text.match(/GC: (\d+) runs \((\d+) minor, (\d+) major\), ([\d.]+) ms = ([\d.]+)% of render time; ([\d.]+) objects\/buffer; longest GC [\d.]+ ms/)
    expect(gc).not_to be_nil, text
    expect(gc[1].to_i).to eq(gc[2].to_i + gc[3].to_i)
    expect(gc[6].to_f).to be > 10

    # Buffer CPU times by GC work; the groups add up to every buffer
    groups = text.match(/buffer CPU \(ms, buffer is 2\.67\): no GC median [\d.]+ p99 [\d.]+ \((\d+)\); GC start median [\d.]+ max [\d.]+ \((\d+)\); GC steps max [\d.]+ \((\d+)\)/)
    expect(groups).not_to be_nil, text
    expect(groups[1..3].sum(&:to_i)).to eq((0.5 * 48000 / 128.0).ceil)
    expect(groups[2].to_i).to be <= gc[1].to_i

    # Per-class self allocations; fused regions report as one entry
    expect(text).to match(/GraphNode::FeedbackLoop +[\d.]+% +[\d.]+ us\/call +\d+ calls +[\d.]+ obj\/call/)
    expect(text).to match(/Plan region \(\d+ nodes, root GraphNode::\w+\) +[\d.]+% +[\d.]+ us\/call +\d+ calls/)
    expect(text).to match(/plans: \d+ regions covering \d+ nodes \(\d+ ops\); \d+ blocks planned, 0 unfused/)
    expect(text).to include('most allocations (self, per buffer):')

    # Allocation sites: five lines under the header, paths relative to the
    # repository, and nothing from graph_profile.rb's own loop
    lines = text.lines
    header = lines.index { |l| l.include?('allocation sites (100 traced buffers)') }
    expect(header).not_to be_nil, text
    sites = lines[(header + 1)..(header + 5)]
    expect(sites).to all(match(/\A +[\d.]+ obj +\d+ B +\S+:\d+ +\S/))
    expect(sites.join).to include('lib/mb/sound/')
    expect(text).not_to include('graph_profile.rb:')
  end

  it 'compares runs with plans off and on' do
    text = `bin/graph_profile.rb -n 128 -s 0.2 --plan both -r 1 bin/effects/flanger.rb 2>&1`
    expect($?).to be_success, text
    expect(text).to match(/flanger\.rb +buffer +128: +[\d.]+% of realtime \(2 outputs, 0\.2 s, plans off\)/)
    expect(text).to match(/best of 1: plans off [\d.]+%, on [\d.]+% of realtime \([-+][\d.]+%\)/)
  end
end
