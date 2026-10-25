# Dynamics nodes as plan ops (Plan::Op::Dynamics: FastDynamics.compand's
# kernel through mb_dynamics.h) against the nodes' own #sample, bit for bit
# (see spec/support/plan_helpers.rb), and the boundaries with reasons.
RSpec.describe(MB::Sound::Plan, 'dynamics ops') do
  let(:src) { PlanSpecHelpers::Source }

  def dyn_ops(r, engine = :c)
    r.regions(engine).flat_map { |reg| reg.program.ops.grep(MB::Sound::Plan::Op::Dynamics) }
  end

  it 'fuses a compressor between other nodes' do
    r = plan_compare { (src.new(seed: 1, scale: 0.9) * 1.5).compress(threshold: -18.db, ratio: 4, attack: 0.001, release: 0.02) * 0.5 }
    expect(dyn_ops(r).length).to eq(1)
    expect(r.regions.first.members.length).to eq(3) # two Multipliers and the compressor
  end

  it 'matches an RMS compressor with hold, upward compression, makeup, and mix' do
    r = plan_compare {
      (src.new(seed: 2, scale: 0.8, kind: :steps, every: 37) * 1).compress(
        threshold: -20.db, ratio: 3, detector: :rms, rms: 0.002, hold: 0.001, upward_threshold: -40.db, makeup: :auto, mix: 0.7,
        attack: 0.0005, release: 0.004
      ) * 1
    }
    expect(dyn_ops(r).length).to eq(1)
  end

  it 'matches expanders, gates, and companders in a chain' do
    r = plan_compare {
      x = src.new(seed: 3, scale: 0.7) * 1
      x.compand({ -60.db => -70.db, -20.db => -20.db, 0.db => -10.db }, interpolation: :cubic).expand(threshold: -30.db).noise_gate(threshold: -50.db) * 1
    }
    expect(dyn_ops(r).length).to eq(3)
  end

  it 'matches node times (an LFO attack, seconds scaled to samples) and a Duration release (tempo)' do
    r = plan_compare {
      x = src.new(seed: 4, scale: 0.9) * 1
      x.compress(threshold: -24.db, attack: 0.0005.constant + 300.hz.asaw.at(0..0.002), release: 1.n64) * 1
    }
    expect(dyn_ops(r).length).to eq(1)
    expect(dyn_ops(r).first.times.grep(MB::Sound::Plan::Value).length).to eq(2)
  end

  it 'matches a duck with a sidechain read as a boundary input' do
    r = plan_compare {
      (src.new(seed: 5, scale: 0.5) * 1).duck(src.new(seed: 6, kind: :steps, every: 50), amount: -12.db, release: 0.003) * 1
    }
    op = dyn_ops(r).first
    expect(op.sides.first.op).to be_a(MB::Sound::Plan::Op::Input)
  end

  it 'flushes a lookahead compressor\'s tail after its input ends (that block unfused)' do
    # (and the block where the input's buffer is short, as every short read)
    r = plan_compare(fallbacks: 2, sizes: [100, 100, 100, 100, 100]) {
      (src.new(seed: 7, scale: 0.9, ends_at: 250) * 1).compress(threshold: -20.db, lookahead: 64.samples) * 0.5
    }
    expect(r.unfused_blocks(:c)).to eq(2)
  end

  it 'stays unfused for limiters, saying why, and names multichannel outputs as computed in their region' do
    text = MB::Sound::Plan.explain(
      (MB::Sound::GraphNode::Channels.new([220.hz.saw * 1, 330.hz.saw * 1]).compress * 1).outputs +
      [(220.hz.saw * 1).limit * 1]
    )
    expect(text).to include('lookahead limiter', 'an output of a 2-channel Dynamics (computed in its region)')
  end

  describe 'several channels (one op computing every channel, fuse-more-1)' do
    def stereo(seed, **kw)
      MB::Sound::GraphNode::Channels.new([src.new(seed: seed, scale: 0.9, **kw) * 1.2, src.new(seed: seed + 1, scale: 0.5) * 0.8])
    end

    def dyn_region(r, engine = :c)
      r.regions(engine).find { |reg| reg.root.is_a?(MB::Sound::GraphNode::Dynamics) }
    end

    it 'runs a linked stereo compressor in one region with its inputs, computing both channels' do
      r = plan_compare { |_c|
        l, rt = stereo(11).compress(threshold: -18.db, ratio: 4, attack: 0.001, release: 0.01).to_a
        l * 0.5 + rt * 0.25
      }
      reg = dyn_region(r)
      expect(reg).not_to be_nil
      op = reg.program.ops.grep(MB::Sound::Plan::Op::Dynamics).first
      expect(op.channels.length).to eq(2)
      expect(op.extra_dsts.length).to eq(1)
      expect(reg.program.ops.grep(MB::Sound::Plan::Op::Output).length).to eq(1)
      expect(reg.members.count { |m| m.is_a?(MB::Sound::GraphNode::Multiplier) }).to eq(2)
      expect(reg.planned_blocks).to be > 0
    end

    it 'matches the right channel read before the left, three linked channels, and an unlinked RMS compressor' do
      plan_compare { |_c|
        l, rt = stereo(12).compress(threshold: -20.db, attack: 0.0005, release: 0.004).to_a
        rt * 0.3 + l
      }
      plan_compare { |_c|
        three = MB::Sound::GraphNode::Channels.new([src.new(seed: 13) * 1, src.new(seed: 14, scale: 0.3) * 1, src.new(seed: 15, kind: :steps, every: 41) * 1])
        a, b, c = three.compress(threshold: -24.db, ratio: 6, hold: 0.001, makeup: :auto).to_a
        a + b * 0.5 - c
      }
      plan_compare { |_c|
        l, rt = stereo(16).compress(threshold: -20.db, detector: :rms, rms: 0.002, link: false, mix: 0.6).to_a
        l - rt
      }
    end

    it 'matches a stereo duck keyed by a sidechain boundary input, and node times' do
      plan_compare { |_c|
        l, rt = stereo(17).duck(src.new(seed: 19, kind: :steps, every: 60), amount: -12.db, release: 0.002 + 200.hz.asaw.at(0..0.001)).to_a
        l + rt
      }
    end

    it 'flushes a stereo lookahead tail after the inputs end (unfused), and ends where unplanned ends when a channel ends first' do
      r = plan_compare(fallbacks: true, sizes: [100] * 10) { |_c|
        st = MB::Sound::GraphNode::Channels.new([src.new(seed: 20, ends_at: 450) * 1, src.new(seed: 21, ends_at: 450) * 1])
        l, rt = st.compress(threshold: -20.db, lookahead: 32.samples).to_a
        l + rt
      }
      expect(r.unfused_blocks(:c)).to be >= 1

      plan_compare(fallbacks: true, sizes: [100] * 10) { |_c|
        st = MB::Sound::GraphNode::Channels.new([src.new(seed: 20, ends_at: 450) * 1, src.new(seed: 21, ends_at: 250) * 1])
        l, rt = st.compress(threshold: -20.db).to_a
        l + rt
      }
    end

    it 'matches in check mode and with the Ruby mirror' do
      plan_compare(check: :raise) { |_c|
        l, rt = stereo(22).compress(threshold: -16.db, lookahead: 8.samples, hold: 0.0005).to_a
        l * 0.7 + rt
      }
      r = plan_compare(engines: [:ruby]) { |_c|
        l, rt = stereo(23).expand(threshold: -30.db).to_a
        l + rt
      }
      expect(dyn_region(r, :ruby)).not_to be_nil
    end
  end

  it 'gives the same samples under check mode' do
    plan_compare(check: :raise) { (src.new(seed: 8, scale: 0.9) * 1).compress(threshold: -12.db, lookahead: 8.samples, hold: 0.0005) * 1 }
  end
end
