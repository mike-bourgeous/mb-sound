RSpec.describe(MB::Sound::PerHarmonic, :aggregate_failures) do
  def ph(*a, **k) = MB::Sound.per_harmonic(*a, **k)

  it 'spreads a Range across the bands along a curve, in the values\' own units' do
    expect(ph(1..3).to_a(3)).to eq([1, 2, 3])
    expect(ph(1.0..3.0).to_a(1)).to eq([1.0])
    expect(ph(15.cents..90.cents).to_a(4).map(&:to_cents)).to eq([15.0, 40.0, 65.0, 90.0])
    expect(ph(100.hz..400.hz).to_a(4).map(&:frequency)).to eq([100.0, 200.0, 300.0, 400.0])
    expect(ph(100.hz..400.hz).value(1, 4)).to be_a(MB::Sound::Pitch)
    expect(ph(-12.db..0.db).to_a(3).map(&:db_value)).to eq([-12.0, -6.0, 0.0])

    exp = ph(0.0..1.0, curve: :exp).to_a(5)
    expect(exp).to eq(Array.new(5) { |i| MB::Sound::Curve[:exp].call(i / 4.0) })
    sq = ph(0.0..1.0, curve: MB::Sound::Curve.power(2)).to_a(3)
    expect(sq).to eq([0.0, 0.25, 1.0])
  end

  it 'spaces an exclusive Range evenly without reaching its end (phases around a cycle)' do
    expect(ph(0...1).to_a(4)).to eq([0.0, 0.25, 0.5, 0.75])
    expect(ph(0...1).to_a(1)).to eq([0.0])
    expect(ph(0.0...1.0, curve: MB::Sound::Curve.power(2)).to_a(2)).to eq([0.0, 0.25])
    expect(ph(0...1).to_ruby).to eq('per_harmonic(0...1)')
    expect(ph(0...1)).not_to eq(ph(0..1))
  end

  it 'gives a list one value per band, repeating' do
    expect(ph(1, 2).to_a(5)).to eq([1, 2, 1, 2, 1])
    expect(ph([3, 4, 5]).to_a(2)).to eq([3, 4])
  end

  it 'prints itself back as Ruby' do
    expect(ph(15.cents..90.cents, curve: :exp).to_ruby).to eq('per_harmonic(15.cents..90.cents, curve: :exp)')
    expect(ph(0.db, -3.db).to_ruby).to eq('per_harmonic(0.db, -3.db)')
    expect(ph(1..2)).to eq(ph(1..2))
    expect(ph(1..2)).to be_frozen
  end

  it 'rejects ranges it can\'t spread' do
    expect { ph }.to raise_error(ArgumentError, /Range or at least one/)
    expect { ph(1.hz..3.0) }.to raise_error(ArgumentError, /one kind/)
    expect { ph(1..) }.to raise_error(ArgumentError, /both ends/)
    expect { ph(1, 2, curve: :exp) }.to raise_error(ArgumentError, /curve/)
    expect { ph(1..2, curve: :bogus) }.to raise_error(ArgumentError, /Unknown curve/)
  end

  describe 'a tone with phase: and rate: spreads' do
    def osc_of(node) = node.is_a?(MB::Sound::GraphNode::Tee::Branch) ? node.original_source : node

    it 'gives each band its own copy of the tone, phases added and rates multiplied' do
      lfo = 0.2.hz.triangle.lfo.at(-0.8..0.8).with_phase(0.1)
      v = ph(lfo, phase: 0...1, rate: 1..2)
      copies = v.to_a(4)
      expect(copies.map(&:class).uniq).to eq([MB::Sound::Tone])
      expect(copies.none? { |c| c.equal?(lfo) }).to eq(true)
      expect(copies.map(&:phase)).to eq([0.1, 0.35, 0.6, 0.85])
      expect(copies.map(&:frequency)).to eq(ph(1..2).to_a(4).map { |r| 0.2 * r })
      expect(copies.map(&:wave_type).uniq).to eq([:triangle])
      expect(copies.map(&:range).uniq).to eq([-0.8..0.8])
      expect(copies.all?(&:lfo?)).to eq(true)

      # each copy plays as the tone built fresh with that phase and rate
      f = 0.2 * ph(1..2).value(2, 4)
      fresh = f.hz.triangle.lfo.at(-0.8..0.8).with_phase(0.6)
      expect(copies[2].sample(4800).to_a).to eq(fresh.sample(4800).to_a)
      expect(lfo.phase).to eq(0.1) # (the tone itself is unchanged)
    end

    it 'takes one value or per-band spreads, and Pitches (which play as sines)' do
      expect(ph(0.2.hz.lfo, phase: 0.25).to_a(2).map(&:phase)).to eq([0.25, 0.25])
      expect(ph(0.2.hz.lfo, phase: [0, 0.5]).to_a(3).map(&:phase)).to eq([0.0, 0.5, 0.0])
      expect(ph(0.2.hz.lfo, phase: ph(0.0..0.5, curve: :exp)).to_a(3).map(&:phase)).to eq(ph(0.0..0.5, curve: :exp).to_a(3))
      expect(ph(0.2.hz.lfo, phase: 90.degrees).to_a(1)[0].phase).to eq(0.25)
      expect(ph(0.2.hz.lfo, rate: 3).to_a(1)[0].frequency).to be_within(1e-12).of(0.6)
      p = ph(0.3.hz, phase: 0...1).to_a(2)
      expect(p.map(&:phase)).to eq([0.0, 0.5])
      expect(p.map(&:wave_type).uniq).to eq([:sine])
    end

    it 'shares the tone\'s inputs through new branches and keeps its timeline lock' do
      rate = 0.5.hz.lfo.at(0.1..0.3)
      lfo = rate.tone.lfo
      a, b = ph(lfo, phase: 0...1).to_a(2)
      expect(osc_of(a.frequency)).to equal(osc_of(lfo.frequency))
      expect(a.frequency).not_to equal(b.frequency)
      ref = 0.5.hz.lfo.at(0.1..0.3).tone.lfo.with_phase(0.5)
      expect(b.sample(9600).to_a).to eq(ref.sample(9600).to_a)
      expect { a.sample(9600) }.not_to raise_error

      t = 2.bars.lfo
      c = ph(t, phase: [0.25]).to_a(1)[0]
      expect(c.timeline).to equal(t.timeline)
      expect(c.phase).to eq(0.25)
    end

    it 'derives seeds from the tone\'s own (seed + 1 + band)' do
      lfo = 0.2.hz.lfo.rnd(seed: 40)
      copies = ph(lfo, phase: 0).to_a(3)
      expect(copies.map(&:seed)).to eq([41, 42, 43])
      expect(lfo.seed).to eq(40)
      expect(copies.map { |c| c.sample(1)[0] }.uniq.length).to eq(3)
    end

    it 'shares no running state with the tone (every instance variable a value, a new branch, or reset)' do
      shared_ok = %i[@tempo @table @zone_table @interpolation]
      tones = [0.2.hz.lfo, 2.bars.lfo, 0.5.hz.lfo.at(0.1..0.3).tone.lfo.at(0..1), 3.hz.saw.pwm(0.3.hz.lfo.at(0.2..0.8)).lfo.gain(0.5.constant),
               5.hz.square.lfo.reset(MB::Sound.seq(MB::Sound::C4.n16).loop.notes.trigger), 1.hz.noise(0.2).lfo]
      tones.each do |t|
        t.sample(100)
        c = ph(t, phase: 0.5).value(0, 1)
        c.sample(100)
        c.instance_variables.each do |iv|
          v = c.instance_variable_get(iv)
          next if [nil, true, false].include?(v) || v.is_a?(Numeric) || v.is_a?(Symbol) || v.frozen? || shared_ok.include?(iv)
          expect(v).not_to equal(t.instance_variable_get(iv)), "#{t} copy shares #{iv} (#{v.class})"
        end
      end
    end

    it 'prints itself back as Ruby' do
      expect(ph(0.2.hz.lfo, phase: 0...1, rate: 1..1.5).to_ruby).to eq('per_harmonic(0.2.hz.lfo, phase: 0...1, rate: 1..1.5)')
      expect(ph(0.2.hz, phase: [0, 0.5]).to_ruby).to eq('per_harmonic(0.2.hz, phase: [0, 0.5])')
      t = 0.2.hz.lfo
      expect(ph(t, phase: 0...1)).to eq(ph(t, phase: 0...1))
      expect(ph(t, phase: 0...1)).not_to eq(ph(0.2.hz.lfo, phase: 0...1))
    end

    it 'rejects what it can\'t spread' do
      expect { ph(0.2.hz.lfo, 0.3.hz.lfo, phase: 0...1) }.to raise_error(ArgumentError, /one tone/)
      expect { ph(0.2.hz.lfo * 2, phase: 0...1) }.to raise_error(ArgumentError, /one tone.*list/)
      expect { ph(0.2.hz.lfo, phase: 0...1, curve: :exp) }.to raise_error(ArgumentError, /curve/)
      expect { ph(0.2.hz.lfo, phase: :x) }.to raise_error(ArgumentError, /phase: takes numbers/)
      expect { ph(0.2.hz.lfo, rate: 1.hz..2.hz) }.to raise_error(ArgumentError, /rate: takes numbers/)
      expect { ph(0.2.hz.lfo, phase: ph(0.2.hz.lfo, phase: 0)) }.to raise_error(ArgumentError, /not a tone/)
      expect { ph(2.bars.lfo, rate: 1..2).to_a(2) }.to raise_error(ArgumentError, /fixed frequency/)
      expect { ph(0.2.hz.lfo, rate: [1, -1]).to_a(2) }.to raise_error(ArgumentError, /positive/)
    end
  end
end
