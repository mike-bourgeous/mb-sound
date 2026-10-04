RSpec.describe('Multiplier and Mixer fast paths') do
  # Builds the graph twice, with and without the fast path, and compares
  # several buffers sample for sample
  def compare(count: 800, buffers: 4, &build)
    fast = build.call
    slow = build.call
    slow.graph.select { |n| n.respond_to?(:arithmetic_fast?, true) }.each do |n|
      n.define_singleton_method(:arithmetic_fast?) { |*| false }
    end

    buffers.times do
      a = fast.sample(count)&.dup
      b = slow.sample(count)&.dup
      expect(a).to eq(b)
    end
  end

  it 'gives the same products' do
    compare { 220.hz.ramp * 330.hz.sine * 0.5.hz.lfo.at(0..1) * 0.7 }
  end

  it 'gives the same sums with gains of 1 and others' do
    compare { 220.hz.ramp + 330.hz.sine * 0.25 + 0.5.hz.lfo - 3 }
  end

  it 'gives the same results for odd buffer sizes' do
    compare(count: 33) { (220.hz.ramp + 330.hz.sine) * 110.hz.triangle }
  end

  it 'falls back for complex inputs and gains' do
    compare { 220.hz.complex_sine * 330.hz.sine + 110.hz.sine * (1 + 1i) }
  end

  it 'falls back for double-precision inputs' do
    data = Numo::DFloat.new(4000).seq.map { |i| Math.sin(i * 0.1) }
    compare { MB::Sound::ArrayInput.new(data: [data]) * 220.hz.sine + 1.constant }
  end

  it 'falls back when an input ends early' do
    data = Numo::SFloat.new(2000).seq.map { |i| Math.sin(i * 0.1) }
    compare(buffers: 6) { MB::Sound::ArrayInput.new(data: [data]) * 220.hz.sine }
  end

  it 'uses the fast path for full buffers of the same type' do
    node = 220.hz.ramp * 330.hz.sine
    expect(node).to receive(:arithmetic_combine).never
    node.sample(800)
  end
end
