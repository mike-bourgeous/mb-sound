# Did-you-mean hints for within (within-hints-1): a signal node's range of
# plain numbers reads note numbers and warns with the Hz form; two ends as
# separate arguments raise, naming the Range form.
RSpec.describe('within hints', :aggregate_failures) do
  let(:s) { MB::Sound }

  it 'warns once per call site when a signal node gets plain numbers, and keeps them as notes' do
    nodes = nil
    expect {
      nodes = Array.new(2) { 100.constant.within(2..8) }
    }.to output(/within\(2\.\.8\) on a signal reads note numbers \(2\.\.8 = 9\.2-13\.0 Hz\); for Hz write within\(2\.hz\.\.8\.hz\)\n\z/).to_stderr
    expect(nodes.map { |n| n.sample(4)[0] }).to eq([12.5, 12.5])
  end

  it 'names an exclusive range and Floats as given' do
    expect { 100.constant.within(2.5...8) }.to output(/within\(2\.5\.\.\.8\) .* within\(2\.5\.hz\.\.\.8\.hz\)/).to_stderr
  end

  it 'stays quiet for Hz, notes, and plain numbers on clips, Seqs, streams, and notes' do
    expect {
      100.constant.within(2.hz..8.hz)
      100.constant.within(s::E1..s::E2)
      s.seq(s::C4).within(40..52)
      s.seq(s::C4).rotate(0).within(40..52)
      s.seq(s::C4).stream.within(40..52)
      s::A4.within(40..52)
    }.not_to output.to_stderr
  end

  it 'raises a did-you-mean naming the Range form for two ends on every within' do
    msg = 'within takes one Range, not 2 arguments (within(E1, E2)); write within(E1..E2)'
    [100.constant, s::A4, s.seq(s::C4), s.seq(s::C4).rotate(0), s.seq(s::C4).stream].each do |x|
      expect { x.within(s::E1, s::E2) }.to raise_error(ArgumentError, msg)
    end
    expect { 100.constant.within(2.hz, 8.hz, 9) }.to raise_error(ArgumentError, /not 3 arguments.*write within\(E1\.\.E2\)/)
  end
end
