# GraphNode::FilterBank as a plan op (Plan::Op::FilterBank, OP_FILTER_BANK):
# mono banks fuse through the node, multichannel banks through their Router
# (a Plan::MultiDescribable), and synth voices' banks run in lane groups;
# samples bit for bit as unplanned (see spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Plan::Op::FilterBank) do
  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  let(:src) { PlanSpecHelpers::Source }

  def bank_region(r, engine = :c)
    r.regions(engine).find { |reg| reg.program.ops.any? { |op| op.is_a?(MB::Sound::Plan::Op::FilterBank) } }
  end

  it 'fuses a mono bank with its input and parameter nodes' do
    r = plan_compare { |_c|
      src.new(seed: 2).bandpass_series(0.5.hz.lfo.at(150..300), count: 6, width: 0.2.hz.lfo.at(5..30), gain: [1, 0.5], normalize: true) * 0.5
    }
    reg = bank_region(r)
    expect(reg).not_to be_nil
    expect(reg.planned_blocks).to be > 0
    expect(reg.members.count { |m| m.is_a?(MB::Sound::Tone) }).to eq(2)
  end

  it 'plans a stereo bank in its router region, in check mode too' do
    r = plan_compare(check: :raise) { |_c|
      l, rt = src.new(seed: 3).bandpass_series(220, count: 4, width: 30.cents, pan: 1.hz.lfo).to_a
      l + rt * 0.25
    }
    expect(bank_region(r).root).to be_a(MB::Sound::GraphNode::FilterBank::Router)
  end

  it 'plans serial banks, formants (a plan boundary before), and banks with constants folded' do
    plan_compare { |_c| src.new(seed: 4).peq(300 => [-6.db, 0.5], 2000 => 4.db) * 0.5 }
    plan_compare { |_c| src.new(seed: 5).formant(:a, :o, morph: 0.3.hz.lfo.at(0..1), shift: 2.hz.lfo.at(-3..3)) * 0.5 }
    plan_compare { |_c| src.new(seed: 6).bandpass_series(300.constant, count: 3, quality: 0 * src.new(seed: 7) + 9) * 0.5 }
  end

  it 'ends with an input that ends' do
    r = plan_compare(fallbacks: 1) { |_c| src.new(seed: 2, ends_at: 1000).bandpass_series(300, count: 3) * 0.5 }
    expect(r.outputs[:unfused].compact.sum(&:length)).to eq(1000)
  end

  it 'groups the banks of every synth voice in lane groups, bit for bit as each lane alone' do
    old = MB::Sound::Plan.lanes
    make = ->(lanes) {
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(0)
      MB::Sound.synth('spec/test_data/c_major.mid', voices: 4, spares: 1, skip_idle: false) { |v|
        (v.amp_env * v.hz.saw * 0.2).bandpass_series(v.hz, count: 8, width: 40.cents, gain: [1, 0.6], normalize: true)
      }
    }
    sizes = [128, 1, 37, 512, 800, 128] * 3
    render = ->(s) { sizes.flat_map { |n| s.sample(n)&.to_a || [] } }
    grouped = make.(true)
    a = render.(grouped)
    expect(grouped.lane_groups.groups.map { |g| g.members.length }.max).to eq(5)
    expect(grouped.lane_groups.groups.sum(&:lane_runs)).to be > 0
    b = render.(make.(false))
    expect(a.length).to be > 3000
    expect(a).to eq(b)
  ensure
    MB::Sound::Plan.lanes = old
  end
end
