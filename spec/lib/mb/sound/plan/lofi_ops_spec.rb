# Decimators (Plan::Op::Decimate) against the unfused graph, bit for bit,
# over block sizes from 1 to 800 (see spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Plan::Op::Decimate) do
  let(:src) { PlanSpecHelpers::Source }

  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  it 'holds at a constant rate that does not divide the sample rate' do
    r = plan_compare { (src.new(seed: 1) * 1).decimate(3001.7) * 0.5 }
    expect(plan_op_names(r)).to include(:Decimate)
  end

  it 'holds at a moving rate, with linear interpolation' do
    r = plan_compare {
      rate = src.new(kind: :steps, seed: 2, every: 61, scale: 4000, offset: 6000) * 1
      (src.new(seed: 3) * 1).decimate(rate, interpolation: :linear) + 0
    }
    expect(plan_op_names(r)).to include(:Decimate)
  end

  it 'reads rates at or above the sample rate, zero, and negative as the kernel does' do
    plan_compare {
      rate = src.new(kind: :steps, seed: 5, every: 40, scale: 60000) * 1
      (src.new(seed: 4) * 1).decimate(rate) * 1
    }
  end

  it 'draws jitter from the node seed, also in check mode' do
    r = plan_compare(check: :raise) { (src.new(seed: 6) * 1).decimate(5000, jitter: 0.6, seed: 77) * 1 }
    expect(plan_op_names(r)).to include(:Decimate)
  end

  it 'blends with a numeric mix' do
    plan_compare { (src.new(seed: 7) * 1).decimate(2500, mix: 0.3) * 1 }
  end

  it 'blends with a moving mix node and a mix Constant of 0 (the wave voices at grit 0)' do
    plan_compare {
      mix = src.new(kind: :steps, seed: 8, every: 90, scale: 0.5, offset: 0.5) * 1
      (src.new(seed: 9) * 1).decimate(4000, mix: mix) * 1
    }
    r = plan_compare { (src.new(seed: 10) * 1).decimate(38461.5, mix: MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000)) * 1 }
    expect(plan_op_names(r)).to include(:Decimate)
  end

  it 'runs with the Ruby mirror (Decimator.process_ruby and .mix)' do
    r = plan_compare(engines: [:ruby]) {
      (src.new(seed: 11) * 1).decimate(src.new(kind: :steps, seed: 12, every: 50, scale: 3000, offset: 5000) * 1, mix: 0.6, jitter: 0.2, seed: 3) * 1
    }
    expect(plan_op_names(r, :ruby)).to include(:Decimate)
  end

  it 'fuses the wave voices into their lane regions at grit 0, 0.5, and 1, with the unplanned samples' do
    render = lambda do |grit, plan|
      old = MB::Sound::Plan.enabled
      MB::Sound::Plan.enabled = plan
      MB::Sound.seed(0)
      g = MB::Sound.preset(:square_bass, midi: MB::Sound.midi_file('spec/test_data/dense_modulated.mid'), grit: grit)
      out = [128, 37, 800, 512, 1].cycle.take(20).map { |n| g.sample(n).dup }
      decimators = g.graph.grep(MB::Sound::GraphNode::Decimator)
      [SpecBuffers.join(out), decimators]
    ensure
      MB::Sound::Plan.enabled = old
    end

    [0.0, 0.5, 1.0].each do |grit|
      planned, decimators = render.(grit, true)
      unplanned, _ = render.(grit, false)
      expect(decimators).not_to be_empty
      expect(decimators).to all(satisfy { |d| d.instance_variable_get(:@plan_member) || d.instance_variable_get(:@plan_region) })
      expect(planned.abs.max).to be > 0.01
      expect(planned.to_binary).to eq(unplanned.to_binary), "grit #{grit}"
    end
  end
end
