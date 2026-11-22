# How a rack is built on stand-ins for printing (Rack#build_on_stand_ins;
# master-rack-1): one channel by default, a stereo bundle for blocks that
# need one (so they save, draw, and list), as many channels as asked for (a
# master chain's capture), channels taken from a stereo stand-in printing as
# sig[0] and sig[1], and knob start values.
RSpec.describe('rack stand-ins', :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:io) { MB::Sound::GraphIO }

  after { MB::Sound::Session.existing&.close }

  def body(text) = text.lines.last.chomp

  def stereo_source
    [220.hz.saw.at(0.4), 330.hz.triangle.at(0.3)].channels
  end

  def run(graph, n = 6)
    Array.new(n) { graph.outputs.map { |c| c.sample(367).dup } }.transpose.map { |c| SpecBuffers.join(c) }
  end

  it 'builds on one channel when the block works on one' do
    r = s.arack { |sig| sig.softclip(0.3, 0.9) }
    _, stand, = r.build_on_stand_ins
    expect(stand[:sig]).to be_a(MB::Sound::GraphNode::Constant)
    expect(body(io.dump(r))).to eq('sig.softclip(0.3, 0.9)')
  end

  it 'builds again on two channels when the block needs a stereo input, so the rack saves and reloads' do
    r = s.arack { |sig| sig.width(1.3).softclip }
    _, stand, = r.build_on_stand_ins
    expect(stand[:sig]).to be_a(MB::Sound::GraphNode::Channels)
    text = io.dump(r)
    expect(body(text)).to eq('sig.width(1.3).softclip')
    loaded = io.load(text)
    expect(io.dump(loaded).sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
    expect(run(loaded.(stereo_source))).to eq(run(r.(stereo_source)))
  end

  it 'prints channels taken from a stereo stand-in as sig[0] and sig[1]' do
    r = s.arack { |sig| [sig.left, sig.right.delay(0.01)].channels }
    text = io.dump(r)
    expect(body(text)).to eq('[sig[0], sig[1].delay(0.01)].channels')
    expect(run(io.load(text).(stereo_source))).to eq(run(r.(stereo_source)))
  end

  it 'builds on as many channels as asked, and starts knobs at given values' do
    r = s.arack { |sig| sig.mono * s.knob(:level, 0.5) }
    expect(body(io.dump(r))).to eq('sig * level') # (one channel: mono changes nothing there)
    text = io.dump(r, stand_ins: { channels: 2, knobs: { level: 0.25 } })
    expect(body(text)).to eq('sig.mono * level')
    expect(text).to include("knob :level, 0.25\n")
    expect { io.dump(1.constant, stand_ins: { channels: 2 }) }.to raise_error(ArgumentError, /stand_ins: goes with racks/)
  end

  it "raises the one-channel build's error when the stereo build fails too" do
    r = s.arack { |sig| sig.no_such_method }
    expect { r.build_on_stand_ins }.to raise_error(NoMethodError, /no_such_method/)
  end
end
