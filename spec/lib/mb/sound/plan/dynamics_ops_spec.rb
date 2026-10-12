# Dynamics nodes as plan ops (Plan::Op::Dynamics: FastDynamics.compand's
# kernel through mb_dynamics.h) against the nodes' own #sample, bit for bit
# (see spec/support/plan_helpers.rb), and the boundaries with reasons.
RSpec.describe(MB::Sound::Plan, 'dynamics ops') do
  let(:src) { PlanSpecHelpers::Source }

  def dyn_ops(r, engine = :c)
    r.regions(engine).flat_map { |reg| reg.program.ops.grep(MB::Sound::Plan::Op::Dynamics) }
  end

  it 'fuses a compressor between other nodes' do
    r = plan_compare { (src.new(seed: 1, scale: 0.9) * 1.5).compress(threshold: -18, ratio: 4, attack: 0.001, release: 0.02) * 0.5 }
    expect(dyn_ops(r).length).to eq(1)
    expect(r.regions.first.members.length).to eq(3) # two Multipliers and the compressor
  end

  it 'matches an RMS compressor with hold, upward compression, makeup, and mix' do
    r = plan_compare {
      (src.new(seed: 2, scale: 0.8, kind: :steps, every: 37) * 1).compress(
        threshold: -20, ratio: 3, detector: :rms, rms: 0.002, hold: 0.001, upward_threshold: -40, makeup: :auto, mix: 0.7,
        attack: 0.0005, release: 0.004
      ) * 1
    }
    expect(dyn_ops(r).length).to eq(1)
  end

  it 'matches expanders, gates, and companders in a chain' do
    r = plan_compare {
      x = src.new(seed: 3, scale: 0.7) * 1
      x.compand({ -60 => -70, -20 => -20, 0 => -10 }, interpolation: :cubic).expand(threshold: -30).noise_gate(threshold: -50) * 1
    }
    expect(dyn_ops(r).length).to eq(3)
  end

  it 'matches node times (an LFO attack, seconds scaled to samples) and a Duration release (tempo)' do
    r = plan_compare {
      x = src.new(seed: 4, scale: 0.9) * 1
      x.compress(threshold: -24, attack: 0.0005.constant + 300.hz.aramp.at(0..0.002), release: 1.n64) * 1
    }
    expect(dyn_ops(r).length).to eq(1)
    expect(dyn_ops(r).first.times.grep(MB::Sound::Plan::Value).length).to eq(2)
  end

  it 'matches a duck with a sidechain read as a boundary input' do
    r = plan_compare {
      (src.new(seed: 5, scale: 0.5) * 1).duck(src.new(seed: 6, kind: :steps, every: 50), amount: -12, release: 0.003) * 1
    }
    op = dyn_ops(r).first
    expect(op.sides.first.op).to be_a(MB::Sound::Plan::Op::Input)
  end

  it 'flushes a lookahead compressor\'s tail after its input ends (that block unfused)' do
    r = plan_compare(fallbacks: 1, sizes: [100, 100, 100, 100, 100]) {
      (src.new(seed: 7, scale: 0.9, ends_at: 250) * 1).compress(threshold: -20, lookahead: 64.samples) * 0.5
    }
    expect(r.unfused_blocks(:c)).to eq(1)
  end

  it 'stays unfused for several channels and for limiters, saying why' do
    text = MB::Sound::Plan.explain(
      (MB::Sound::GraphNode::Channels.new([220.hz.ramp * 1, 330.hz.ramp * 1]).compress * 1).outputs +
      [(220.hz.ramp * 1).limit * 1]
    )
    expect(text).to include('2-channel Dynamics', 'lookahead limiter')
  end

  it 'gives the same samples under check mode' do
    plan_compare(check: :raise) { (src.new(seed: 8, scale: 0.9) * 1).compress(threshold: -12, lookahead: 8.samples, hold: 0.0005) * 1 }
  end
end
