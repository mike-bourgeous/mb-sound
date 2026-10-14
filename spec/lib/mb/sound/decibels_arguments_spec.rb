# The one rule for dB-valued arguments outside dynamics (db-1 round 2;
# dynamics are in graph_node/dynamics_spec.rb): Decibels exact, bare numbers
# linear gains, bare negatives raise (read as dB in live mode), old graph
# documents converted on load.  Envelope and Curve shapes keep bare numbers
# as signed dB and take Decibels too.
RSpec.describe('dB-valued arguments', :aggregate_failures) do
  describe MB::Sound::Decibels do
    it 'reads Decibels exactly and bare numbers as linear gains' do
      expect(MB::Sound::Decibels.db_of(-12.db, 'x')).to eq(-12.0)
      expect(MB::Sound::Decibels.db_of(0.5, 'x')).to eq(20 * Math.log10(0.5))
      expect(MB::Sound::Decibels.gain_of(-12.db, 'x')).to eq((-12).db.to_f)
      expect(MB::Sound::Decibels.gain_of(0.5, 'x')).to eq(0.5)
      expect(MB::Sound::Decibels.db_of(0, 'x', zero: true)).to eq(-Float::INFINITY)
      expect { MB::Sound::Decibels.db_of(-3, 'x') }.to raise_error(ArgumentError, /x: -3 is a linear gain.*write -3\.db/)
      expect { MB::Sound::Decibels.db_of(0, 'x') }.to raise_error(ArgumentError, /x: 0 is a linear gain of zero/)
      expect { MB::Sound::Decibels.db_of(:loud, 'x') }.to raise_error(ArgumentError, /x must be a number/)
    end

    it 'reads bare negative numbers as dB in live mode, warning once per call site' do
      MB::Sound.live = true
      v = nil
      expect { 2.times { v = MB::Sound::Decibels.gain_of(-6, 'level') } }.to output(/\A[^\n]*: warning: level: -6 is read as -6 dB in live mode; write -6\.db[^\n]*\n\z/).to_stderr
      expect(v).to eq(10.0 ** (-6 / 20.0))
      expect { v = MB::Sound::Decibels.db_of(-6, 'level2') }.to output(/level2: -6 is read as -6 dB/).to_stderr
      expect(v).to eq(-6.0)
    ensure
      MB::Sound.live = false
    end
  end

  describe 'drum accent and more cowbell' do
    def hits
      MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 0, 0, 0, 0.75, 0, 0, 0]])
    end

    def ratio_db(accent)
      out = MB::Sound::Drums.accented(hits, accent, curve: :grid).sample(8)
      20 * Math.log10(out[0] / out[4])
    end

    it 'takes Decibels exactly and bare numbers as linear gains' do
      expect(ratio_db(6.db)).to be_within(1e-4).of(6)
      expect(ratio_db(2)).to be_within(1e-4).of(20 * Math.log10(2))
      expect { MB::Sound::Drums.accented(hits, 6 * -1) }.to raise_error(ArgumentError, /accent: -6/)
      expect { MB::Sound::Drums.accented(hits, -6.db) }.to raise_error(ArgumentError, /0 dB or more/)

      a = MB::Sound::Drums::TR808.more_cowbell({}, 6.db)
      b = MB::Sound::Drums::TR808.more_cowbell({}, 6.db.to_f)
      expect(a[:level]).to be_within(1e-12).of(b[:level]) # (a bare gain is measured in dB)
      expect(MB::Sound::Drums::TR808.more_cowbell({}, true)).to eq(a)
    end
  end

  describe 'filter gains' do
    it 'reads peq and biquad gains as Decibels exactly, bare numbers as linear' do
      exact = 220.hz.ramp.peq(1000.hz => -7.db).sample(800)
      linear = 220.hz.ramp.peq(1000.hz => (-7).db.to_f).sample(800)
      expect((exact - linear).abs.max).to be < 1e-6 # (to_db of the gain is within an ulp of -7)
      expect { 220.hz.ramp.peq(1000.hz => -7) }.to raise_error(ArgumentError, /gain: -7/)
      expect { 220.hz.ramp.filter(:peak, cutoff: 900, gain: -6) }.to raise_error(ArgumentError, /gain: -6/)
      expect { 220.hz.ramp.filter(:peak, cutoff: 900, gain: -6, structure: :biquad) }.to raise_error(ArgumentError, /gain: -6/)
    end

    it 'keeps db_gain: (named in dB) as dB, and takes Decibels there exactly' do
      expect(MB::Sound::Filter::Cookbook.new(:peak, 48000, 1000, db_gain: 6.db, quality: 1).db_gain).to eq(6.0)
      expect(MB::Sound::Filter::Cookbook.new(:peak, 48000, 1000, db_gain: 6, quality: 1).db_gain).to eq(6)
      expect(MB::Sound::Filter::SVF.new(:peak, 48000, 1000, db_gain: 6.db, quality: 1).db_gain).to be_within(1e-12).of(6)
    end
  end

  describe 'reverb duck:' do
    it 'is the wet gain while ducked' do
      expect { 1.constant.reverb(:room, duck: 2) }.to raise_error(ArgumentError, /at most 0 dB/)
      expect { 1.constant.reverb(:room, duck: -12) }.to raise_error(ArgumentError, /duck: -12/)
    end
  end

  describe 'chorus hiss:, onset levels, and help.level' do
    it 'reads chorus hiss as a level' do
      quiet = 0.constant.chorus(hiss: -60.db, seed: 1)
      same = 0.constant.chorus(hiss: (-60).db.to_f, seed: 1)
      expect(quiet[0].sample(800)).to eq(same[0].sample(800))
      expect { 0.constant.chorus(hiss: -60) }.to raise_error(ArgumentError, /hiss: -60/)
    end

    it 'reads onset threshold and floor in dB' do
      x = Numo::SFloat.zeros(48000)
      [3000, 15000, 30001].each { |at| x[at...(at + 2000)] = Numo::SFloat.cast(Numo::DFloat.new(2000).seq.map { |i| Math.sin(i * 0.7) * Math.exp(-i / 400.0) }) }
      s = MB::Sound::Sample[x]
      expect(s.onsets(threshold: 9.db, floor: -45.db)).to eq(s.onsets)
      expect(s.onsets(threshold: 9.db.to_f, floor: (-45).db.to_f)).to eq(s.onsets)
      expect { s.onsets(floor: -45) }.to raise_error(ArgumentError, /floor: -45/)
    end
  end

  describe 'curve shapes' do
    it 'take Decibels as their signed dB, and bare numbers as dB as before' do
      expect(MB::Sound::Curve.db(60.db).(0.25)).to eq(MB::Sound::Curve.db(60).(0.25))
      expect(MB::Sound::Curve.s(-12.db).(0.25)).to eq(MB::Sound::Curve.s(-12).(0.25))
      expect(MB::Sound::Envelope.curve_values(60.db)).to eq(MB::Sound::Envelope.curve_values(60))
      expect(MB::Sound::Envelope.curve_values([0, -12.db, 30.db])).to eq(MB::Sound::Envelope.curve_values([0, -12, 30]))
      a = MB::Sound.adsr(0.01, 0.1, 0.5, 0.1, curve: 60.db).sample(800)
      b = MB::Sound.adsr(0.01, 0.1, 0.5, 0.1, curve: 60).sample(800)
      expect(a).to eq(b)
    end
  end

  describe 'graph documents before format 3' do
    it 'load drum accents, reverb ducks, chorus hiss, and custom vowel levels as dB, warning once' do
      old = <<~DOC
        graph 2, name: "old"
        inputs :input
        mix = input.reverb(:room, duck: 12).chorus(:juno1, hiss: -60, seed: 3).formant([[500, 0, 50], [1500, -6, 80], [2500, -12, 100], [3500, -20, 120], [4500, -30, 150]])
        mix + tr808(grid(16, kick: 'X.x.').loop, accent: 8, snare: { accent: 3 }, more_cowbell: 4)
      DOC
      g = nil
      expect { g = MB::Sound::GraphIO.load(old, inputs: { input: 220.hz.ramp }) }.to output(/\A[^\n]*format 2 document: bare dB values[^\n]*\n\z/).to_stderr
      code = g.to_ruby
      expect(code).to include('duck: -12.db', 'hiss: -60.db', '[500, 0.db, 50], [1500, -6.db, 80]', 'accent: 8.db', 'snare: { accent: 3.db }', 'more_cowbell: 4.db')
    end
  end
end
