# Resonators (Plan::Op::Resonator: GraphNode::Resonator's ping and
# ModalResonator's bank) against the unfused graph, bit for bit, over block
# sizes from 1 to 800 (see spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Plan::Op::Resonator) do
  let(:src) { PlanSpecHelpers::Source }

  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  let(:hits) { src.new(kind: :impulses, at: [0, 3, 130, 801, 1500, 2399], value: 0.8) }

  it 'pings at a numeric frequency and decay, with a phase' do
    r = plan_compare { (hits * 1).ping(220, decay: 0.05, phase: 0.25) * 0.5 }
    expect(plan_op_names(r)).to include(:Resonator)
  end

  it 'pings at a moving frequency and a moving decay node (seconds scaled to samples)' do
    r = plan_compare {
      f = src.new(kind: :steps, seed: 2, every: 37, scale: 300, offset: 400) * 1
      d = src.new(kind: :steps, seed: 3, every: 91, scale: 0.02, offset: 0.04) * 1
      (src.new(seed: 1) * 0.01).ping(f, decay: d) * 1
    }
    expect(plan_op_names(r)).to include(:Resonator)
  end

  it 'pings with decays of zero and below (silence) and a decay in samples' do
    plan_compare {
      d = src.new(kind: :steps, seed: 4, every: 50, scale: 400, offset: -100) * 1
      (hits * 1).ping(880, decay: d.samples) * 1
    }
  end

  it 'runs a modal bank (a bowl with doublets, a gong with bloom twins and a glide)' do
    r = plan_compare { (hits * 1).resonate(:bowl, 330) * 1 + (hits * 0.5).resonate(:gong, decay: 0.3) * 1 }
    ops = r.program.ops.grep(MB::Sound::Plan::Op::Resonator)
    expect(ops.length).to be >= 2
    expect(ops.count(&:modal?)).to eq(2)
  end

  it 'rings out unfused after its input ends, on the same sample as the node' do
    plan_compare(fallbacks: true) { (src.new(kind: :impulses, at: [0, 400], ends_at: 900) * 1).ping(440, decay: 0.01) * 1 }
  end

  # Kaede's 22 (panel 2): a gong's tension glide (a ping of its own) or any
  # frequency or decay node ending ended the resonator with it
  it 'holds the last value of a frequency or decay node that ends, ringing on' do
    plan_compare(fallbacks: true) {
      f = (src.new(kind: :steps, seed: 6, every: 50, scale: 300, offset: 400, ends_at: 700) * 1)
      d = (src.new(kind: :steps, seed: 7, every: 80, scale: 0.02, offset: 0.05, ends_at: 1100) * 1)
      (hits * 1).ping(f, decay: d) * 1 + (hits * 0.5).resonate(:gong, 220, decay: 0.3, glide_time: 0.004) * 1
    }
    node = (src.new(kind: :impulses, at: [0], value: 1, ends_at: 10) * 1).ping(src.new(kind: :steps, seed: 8, every: 50, scale: 1, offset: 440, ends_at: 300), decay: 0.02)
    lengths = []
    while (b = node.sample(256)); lengths << b.length; end
    expect(lengths.sum).to be > 0.02 * 48000 # (rang out past the frequency node's end at 300)
  end

  it 'runs with the Ruby mirrors (Resonator.process_ruby and ModalResonator.process_ruby)' do
    r = plan_compare(engines: [:ruby]) {
      f = src.new(kind: :steps, seed: 5, every: 70, scale: 200, offset: 300) * 1
      (hits * 1).ping(f, decay: 0.03) * 1 + (hits * 1).resonate(:chime, f) * 1
    }
    expect(plan_op_names(r, :ruby)).to include(:Resonator)
  end

  it 'keeps states equal in check mode' do
    plan_compare(check: :raise) { (hits * 1).resonate(:glass, 660) * 1 + (hits * 1).ping(110, decay: 0.2) * 1 }
  end

  it 'fuses a TR-808 kick voice graph into one region' do
    kit = MB::Sound.tr808(MB::Sound.grid(16, 'x...x...').loop)
    voice = kit.voices[:kick]
    3.times { kit.sample(128) }
    text = MB::Sound::Plan.explain(voice.graph)
    expect(text).to start_with('1 planned region')
    expect(text).to include('ping(')
  end
end
