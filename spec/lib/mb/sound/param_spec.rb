RSpec.describe(MB::Sound::Param) do

  after { MB::Sound.live = false }

  describe '.declare' do
    it 'takes its type from the default and its range' do
      p = described_class.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz, description: 'Lowpass center')
      expect(p.type).to eq(:frequency)
      expect(p.curve).to eq(:exp)
      expect(p.magnitude_range).to eq(150.0..8000.0)
      expect(p.implied).to eq(false)
    end

    it 'spells ranged defaults as (lo..hi).at(default) or default.in(lo..hi)' do
      a = described_class.declare(:cutoff, (150.hz..8000.hz).at(2400.hz))
      b = described_class.declare(:cutoff, 2400.hz.in(150.hz..8000.hz))
      c = described_class.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz)
      expect(a).to eq(c)
      expect(b).to eq(c)
      expect((0.1..1.0).at(0.5).to_ruby).to eq('(0.1..1.0).at(0.5)')
    end

    it 'gives every unit value #in' do
      [[2400.hz, 150.hz..8000.hz], [2.4.seconds, 0.1.seconds..30.seconds], [-12.db, -60.db..0.db], [12.cents, 0.cents..50.cents],
       [1.n16, 1.n64..1.n4], [0.25.cycles, 0.cycles..1.cycles], [480.samples, 1.samples..4800.samples],
       [MB::Sound::A4, MB::Sound::A3..MB::Sound::A5]].each do |v, r|
        expect(v.in(r)).to eq(r.at(v))
        expect(described_class.declare(:x, v.in(r)).magnitude_range).to eq(described_class.magnitude(r.begin).to_f..described_class.magnitude(r.end).to_f)
      end
    end

    it 'refuses a range given twice' do
      expect { described_class.declare(:x, (0.0..1.0).at(0.5), range: 0.0..2.0) }.to raise_error(described_class::Error, /range once/)
    end

    it 'makes Integer ranges with Integer defaults stepped, and Arrays choices' do
      expect(described_class.declare(:count, 3, range: 1..8).stepped?).to eq(true)
      expect(described_class.declare(:cutoff, 1400.0, range: 20..10000).stepped?).to eq(false) # (graph documents' loose ranges)
      e = described_class.declare(:mode, :tape, range: %i[tape bbd digital])
      expect(e.enum?).to eq(true)
      expect(e.type).to eq(:name)
    end

    it 'defaults curves by type: exp for frequencies and times, dB-linear for decibels, switch for booleans' do
      expect(described_class.declare(:a, 0.1.seconds, range: 1.ms..2.seconds).curve).to eq(:exp)
      expect(described_class.declare(:a, 1.n8, range: 1.n64..1.n2).curve).to eq(:exp)
      expect(described_class.declare(:g, -12.db, range: -60.db..0.db).curve).to eq(:exp)
      expect(described_class.declare(:on, true).curve).to eq(:switch)
      expect(described_class.declare(:x, 0.5, range: 0.0..1.0).curve).to eq(:linear)
      expect(described_class.declare(:x, 0.5.seconds, range: 0.seconds..1.seconds).curve).to eq(:linear) # (exp can't touch 0)
    end

    it 'accepts the old curve names as aliases of the canonical ones' do
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :exponential).curve).to eq(:exp)
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :log).curve).to eq(:exp)
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :db).curve).to eq(:exp)
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :lin).curve).to eq(:linear)
      expect(described_class.declare(:on, true, curve: :enum).curve).to eq(:switch)
      expect(described_class::CURVES.values.uniq).to eq(%i[linear exp switch fader])
    end

    it 'takes ranges and curves from the names table when the default has its type' do
      p = described_class.declare(:cutoff, 800.hz)
      expect(described_class.value_key(p.range)).to eq(described_class.value_key(20.hz..20000.hz))
      expect(p.curve).to eq(:exp)
      expect(p.implied).to eq(true)
      expect(described_class.declare(:voices, 4).range).to eq(1..32)
      expect(described_class.declare(:voices, 4).stepped?).to eq(true)
      expect(described_class.declare(:reso, 0.3).range).to eq(0.0..1.0)
      expect(described_class.declare(:"dub/mix", 0.3).range).to eq(0.0..1.0)
      expect(described_class.declare(:attack, 10.ms).range).to eq(0.1.ms..10.seconds)
      expect(described_class.declare(:attack, 10.ms).curve).to eq(:exp)
      expect(described_class.declare(:detune, 12.cents).range).to eq(0.cents..150.cents)
      cs = described_class.declare(:release, 0.5.seconds).control_spec(number: 72)
      expect(cs.curve).to eq(:exp) # (time names on MIDI CC map exponentially)
      expect(cs.value(0)).to be_within(1e-12).of(0.0001)
      expect(cs.value(127)).to be_within(1e-9).of(30.0)
    end

    it 'leaves plain numbers out of typed table entries unless type: says their unit' do
      expect(described_class.declare(:cutoff, 2400.0).range).to be_nil # (a plain number's unit is unknown)
      expect(described_class.declare(:gain, 0.0).range).to be_nil
      t = described_class.declare(:cutoff, 2400.0, type: :frequency)
      expect(t.range).to eq(20.0..20000.0)
      expect(t.curve).to eq(:exp)
      expect(t.unit).to eq('Hz')
    end

    it 'lets explicit ranges win over the names table' do
      expect(described_class.declare(:mix, 50.0, range: 0.0..100.0, unit: '%').range).to eq(0.0..100.0)
    end

    it 'checks the default against its range, with the description and a spelling that works' do
      expect { described_class.declare(:cutoff, 9000.hz, range: 150.hz..8000.hz, description: 'Lowpass') }.to raise_error(described_class::Error, /cutoff: the default 9000.hz is outside 150.hz..8000.hz \(Lowpass\)/)
      # (units once, omnibus15: a plain default beside a typed range takes its unit)
      expect(described_class.declare(:cutoff, 2400, range: 150.hz..8000.hz).to_ruby).to eq('param :cutoff, (150.hz..8000.hz).at(2400.hz)')
      expect { described_class.declare(:cutoff, 2400, range: 150.0.semitones..8000.0.semitones, type: :frequency) }.to raise_error(described_class::Error)
      expect { described_class.declare(:mix, 1.5) }.to raise_error(described_class::Error, /mix: the default 1.5 is outside 0.0..1.0; limited to 1.0 \(clamp: false lets it leave the range\)/)
      expect { described_class.declare(:x, (0.0..1.0).at(2.0)) }.to raise_error(described_class::Error, /outside/)
      expect((0.0..1.0).at(2.0).default).to eq(2.0) # (the declaration checks; clamp: false may allow it)
      expect((0.0..1.0).at(2.hz).to_ruby).to eq('(0.hz..1.hz).at(2.hz)') # (units once)
      expect { (0.0.semitones..1.0.semitones).at(2.hz) }.to raise_error(described_class::Error, /isn't|mixes/)
    end

    it 'limits defaults outside their range live, and lets clamp: false params leave it' do
      MB::Sound.live = true
      p = nil
      expect { p = described_class.declare(:cutoff, 9000.hz, range: 150.hz..8000.hz) }.to output(/limited to 8000.hz/).to_stderr
      expect(p.default.frequency).to eq(8000.0)
      MB::Sound.live = false
      w = described_class.declare(:wild, 3.0, range: 0.0..1.0, clamp: false)
      expect(w.default).to eq(3.0)
      expect(w.check(-2.0)).to eq(-2.0)
      expect(w.clamp).to eq(false)
      expect { described_class.declare(:x, 1, clamp: :maybe) }.to raise_error(described_class::Error, /clamp/)
    end

    it 'checks range ends, curves, units, and choices' do
      expect { described_class.declare(:x, 1.0, range: 2.0..1.0) }.to raise_error(described_class::Error, /must go up/)
      expect { described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :exponentail) }.to raise_error(described_class::Error) { |e| expect(e.suggestions).to eq([':exponential']) }
      expect { described_class.declare(:x, 0.5, range: 0.0..1.0, curve: :exp) }.to raise_error(described_class::Error, /can't include or cross 0/)
      expect { described_class.declare(:x, 2.hz, unit: 'Hz') }.to raise_error(described_class::Error, /carries its own unit/)
      expect { described_class.declare(:mode, :tap, range: %i[tape bbd]) }.to raise_error(described_class::Error) { |e| expect(e.suggestions).to eq([':tape']) }
      expect { described_class.declare(:x, 1, type: :frequncy) }.to raise_error(described_class::Error) { |e| expect(e.suggestions).to include(':frequency') }
      expect { described_class.declare(:x, 1.hz, type: :seconds) }.to raise_error(described_class::Error, /doesn't match/)
      expect { described_class.declare(:x, 1, cc: 200) }.to raise_error(described_class::Error, /cc/)
      expect { described_class.declare('x', 1) }.to raise_error(described_class::Error, /Symbols/)
    end
  end

  describe '#check' do
    let(:cut) { described_class.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz, description: 'Lowpass') }

    it 'passes values inside the range, typed or plain in the base unit, and graph nodes' do
      expect(cut.check(3000.hz).frequency).to eq(3000.0)
      expect(cut.check(3000.0)).to eq(3000.0)
      node = 0.5.constant
      expect(cut.check(node)).to equal(node)
    end

    it 'raises outside live mode for values out of range' do
      expect { cut.check(9000.hz, what: 'turn :cut') }.to raise_error(described_class::Error, /turn :cut: 9000.hz is outside 150.hz..8000.hz \(Lowpass\); limited to 8000.hz/)
      expect { cut.check(2.seconds) }.to raise_error(described_class::Error, /isn't a frequency/)
    end

    it 'warns and limits the value in live mode' do
      MB::Sound.live = true
      expect { expect(cut.check(9000.hz).frequency).to eq(8000.0) }.to output(/limited to 8000.hz/).to_stderr
      expect { expect(described_class.declare(:mix, 0.5).check(3.0)).to eq(1.0) }.to output(/mix: 3.0 is outside 0.0..1.0/).to_stderr
    end

    it 'checks choices' do
      e = described_class.declare(:mode, :tape, range: %i[tape bbd])
      expect(e.check(:bbd)).to eq(:bbd)
      expect { e.check(:bdd) }.to raise_error(described_class::Error) { |x| expect(x.suggestions).to eq([':bbd']) }
    end
  end

  describe 'conversions' do
    it 'turns values into base-unit numbers and back' do
      expect(described_class.magnitude(2400.hz)).to eq(2400.0)
      expect(described_class.magnitude(250.ms)).to eq(0.25)
      expect(described_class.magnitude(-20.db)).to be_within(1e-12).of(0.1)
      expect(described_class.magnitude(7.semitones)).to eq(7.0)
      expect(described_class.magnitude(1.n4)).to eq(0.25)
      p = described_class.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz)
      expect(p.typed(500.0).frequency).to eq(500.0)
      expect(described_class.declare(:g, -6.db, range: -60.db..0.db).typed(0.5).decibels).to be_within(1e-6).of(-6.0206)
      expect(described_class.declare(:x, 0.5).typed(0.25)).to eq(0.25)
    end
  end

  describe 'printing' do
    it 'prints the canonical declaration, leaving out what the name implies' do
      expect(described_class.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz, description: 'Lowpass').to_ruby).to eq('param :cutoff, (150.hz..8000.hz).at(2400.hz), description: "Lowpass"')
      expect(described_class.declare(:cutoff, 800.hz).to_ruby).to eq('param :cutoff, 800.hz')
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :exp, unit: 'x').to_ruby).to eq('param :x, (0.1..10.0).at(1.0), curve: :exp, unit: "x"')
      expect(described_class.declare(:mode, :tape, range: %i[tape bbd]).to_ruby).to eq('param :mode, :tape, range: [:tape, :bbd]')
    end

    it 'prints graph-document lines (format 5) in the canonical spelling, typed as declared' do
      p = described_class.declare(:cutoff, 2400.0, range: 150.0..8000.0, description: 'Reese lowpass center in Hz', cc: 74)
      expect(p.document_line).to eq('param :cutoff, (150.0..8000.0).at(2400.0), cc: 74, description: "Reese lowpass center in Hz"')
      expect(p.document_line(3000.0)).to start_with('param :cutoff, (150.0..8000.0).at(3000.0), ')
      expect(described_class.declare(:x, 1.0, range: 0.1..10.0, curve: :exp, unit: 'Hz').document_line).to eq('param :x, (0.1..10.0).at(1.0), curve: :exp, unit: "Hz"')
      t = described_class.declare(:cut, (150.hz..8000.hz).at(2400.hz))
      expect(t.document_line(3000.0)).to eq('param :cut, (150.hz..8000.hz).at(3000.hz)')
      expect(described_class.declare(:wild, (0.0..1.0).at(3.0), clamp: false).document_line).to eq('param :wild, (0.0..1.0).at(3.0), clamp: false')
    end

    it 'prints a help line' do
      expect(described_class.declare(:cutoff, 2400.hz).help_line).to match(/\Acutoff +2400.hz +20.hz..20000.hz exp +Filter cutoff\z/)
      expect(described_class.declare(:voices, 4).help_line).to include('1..32 stepped')
    end
  end

  describe 'ArgTypes' do
    it 'is the record ArgTypes signatures take' do
      expect(MB::Sound::ArgTypes::Param).to equal(described_class)
      p = MB::Sound::ArgTypes::Param.new(name: :root, types: { frequency: 'the root' }, default: 220.hz)
      expect(p.takes?(:frequency)).to eq(true)
      expect(described_class.declare(:root, 220.hz).types).to eq({ frequency: 'a frequency (220.hz or v.freq)' })
    end
  end

  describe 'Range#at and Numeric#in' do
    it "don't shadow other methods" do
      expect(Range.instance_method(:at).owner).to eq(described_class::RangeAt)
      expect(Numeric.instance_method(:in).owner).to eq(described_class::ValueIn)
      expect(440.hz.at(0.5)).to be_a(MB::Sound::Tone) # (Pitch#at is amplitude)
      expect(MB::Sound::Curve.instance_method(:in).owner).to eq(MB::Sound::Curve)
    end
  end
end
