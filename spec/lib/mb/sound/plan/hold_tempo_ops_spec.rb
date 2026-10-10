# Sample and hold (Plan::Op::SampleHold) and tempo values (TempoNode as a
# param) against the unfused graph, bit for bit, over block sizes from 1 to
# 800 (see spec/support/plan_helpers.rb).
RSpec.describe('plan ops for SampleHold and TempoNode') do
  let(:src) { PlanSpecHelpers::Source }

  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  describe MB::Sound::Plan::Op::SampleHold do
    it 'holds a source at rising edges of a trigger' do
      r = plan_compare {
        trig = src.new(kind: :steps, seed: 2, every: 37)
        (src.new(seed: 1) * 1).sample_hold(trig * 1) * 0.5
      }
      expect(plan_op_names(r)).to include(:SampleHold)
    end

    it 'holds random values (seeded draws) at the edges of a square LFO, also in check mode' do
      r = plan_compare(check: :raise) { (90.hz.lfo.asquare.sample_hold(range: 2..5) * src.new(seed: 3)) }
      expect(plan_op_names(r)).to include(:SampleHold)
    end

    it 'catches edges at block boundaries and a trigger high from the start' do
      plan_compare(sizes: [1, 1, 5, 64, 3, 128, 1, 1, 200]) {
        trig = src.new(kind: :impulses, at: [0, 1, 2, 7, 69, 70, 72, 200, 201], value: 1.0)
        (src.new(seed: 4) * 2).sample_hold(trig * 1) + 0
      }
    end

    it 'runs with the Ruby mirror (SampleHold#process)' do
      r = plan_compare(engines: [:ruby]) { (src.new(seed: 1) * 1).sample_hold(src.new(kind: :steps, seed: 5, every: 50) * 1) * 1 }
      expect(plan_op_names(r, :ruby)).to include(:SampleHold)
    end
  end

  describe 'TempoNode params' do
    it 'reads a :seconds tempo node every block' do
      r = plan_compare { |c|
        t = MB::Sound::Sequence::TempoNode.new(1.n32, mode: :seconds)
        t * src.new(seed: 1) * 4
      }
      expect(r.program.params.map { |op| op.constant.class }).to include(MB::Sound::Sequence::TempoNode)
    end

    it 'follows tempo changes between blocks' do
      plan_compare { |c|
        transport = MB::Sound::Sequence::Transport.new(bpm: 120)
        t = MB::Sound::Sequence::TempoNode.new(3.n16, mode: :hz, transport: transport)
        c.before_block(4) { transport.bpm = 90 }
        c.before_block(9) { transport.bpm = 150 }
        t * src.new(seed: 2) * 0.1
      }
    end

    it 'stays a boundary while its timeline ports are in use' do
      t = MB::Sound::Sequence::TempoNode.new(1.beat, mode: :hz)
      t.jumps
      expect(t.plan_unsupported_reason).to match(/ports/)
    end
  end
end
