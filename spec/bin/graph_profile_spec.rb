require 'shellwords'

RSpec.describe('bin/graph_profile.rb') do
  it 'reports cost, GC, per-class allocations, and allocation sites' do
    text = `bin/graph_profile.rb -n 128 -s 0.5 --profile -a 5 bin/effects/flanger.rb 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/flanger\.rb +buffer +128: +[\d.]+% of realtime \(2 outputs, 0\.5 s, profiled\)/)

    # GC.stat deltas: the flanger allocates objects every buffer
    gc = text.match(/GC: (\d+) runs \((\d+) minor, (\d+) major\), ([\d.]+) ms = ([\d.]+)% of render time; ([\d.]+) objects\/buffer/)
    expect(gc).not_to be_nil, text
    expect(gc[1].to_i).to eq(gc[2].to_i + gc[3].to_i)
    expect(gc[6].to_f).to be > 10

    expect(text).to match(/longest GC [\d.]+ ms; slowest buffer doing GC work [\d.]+ ms \(\d+ buffers\), p99 of others [\d.]+ ms; buffer is 2\.67 ms/)

    # Per-class self allocations
    expect(text).to match(/GraphNode::Multiplier +[\d.]+% +[\d.]+ us\/call +\d+ calls +[\d.]+ obj\/call/)
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
end
