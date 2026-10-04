RSpec.describe(MB::Sound::Tuning, :aggregate_failures) do
  let(:tuning) { MB::Sound::Tuning.new }

  it 'defaults to A4 = 440 Hz' do
    expect(tuning.note).to eq(69)
    expect(tuning.frequency).to eq(440)
    expect(tuning.frequency_of(69)).to eq(440)
    expect(tuning.frequency_of(57)).to eq(220)
    expect(tuning.frequency_of(MB::Sound::C4.number)).to be_within(1e-9).of(261.6255653005986)
  end

  it 'converts frequencies back to fractional note numbers' do
    expect(tuning.number_of(440)).to eq(69)
    expect(tuning.number_of(880)).to eq(81)
    expect(tuning.number_of(466.1637615180899)).to be_within(1e-9).of(70)
    expect(tuning.number_of(0)).to eq(-Float::INFINITY)
  end

  it 'applies detuning in cents' do
    expect(tuning.frequency_of(69, 100)).to be_within(1e-9).of(tuning.frequency_of(70))
  end

  describe '#set' do
    it 'accepts a note name and frequency' do
      tuning.set(b4: 480)
      expect(tuning.note).to eq(71)
      expect(tuning.frequency_of(71)).to eq(480)
      expect(tuning.frequency_of(69)).to be_within(1e-9).of(480 * 2**(-2 / 12.0))
    end

    it 'accepts a note number and frequency' do
      tuning.set(note: 60, frequency: 256)
      expect(tuning.frequency_of(72)).to eq(512)
    end

    it 'rejects several names or bad frequencies' do
      expect { tuning.set(a4: 440, b4: 480) }.to raise_error(ArgumentError, /one note name/)
      expect { tuning.set(a4: 0) }.to raise_error(ArgumentError, /positive/)
    end

    it 'can be reset' do
      tuning.set(a4: 432).reset
      expect(tuning.frequency_of(69)).to eq(440)
    end
  end

  describe '#freq' do
    it 'converts note numbers from a node, following tuning changes' do
      node = tuning.freq(69.constant)
      expect(node.sample(4).to_a).to all(be_within(1e-3).of(440))
      tuning.set(a4: 442)
      expect(node.sample(4).to_a).to all(be_within(1e-3).of(442))
    end

    it 'leaves a shared input buffer alone', :check_shared do
      src = 69.constant + 2.hz.lfo.at(12)
      f = tuning.freq(src)
      other = src.get_sampler
      3.times do
        hz = f.sample(480).dup
        num = other.sample(480).dup
        expect(num.max).to be > 70
        expect(hz).to all_be_within(1e-2).of_array(440 * 2 ** ((num - 69) / 12))
      end
    end

    it 'leaves an unshared input buffer alone' do
      data = Numo::SFloat[60, 69, 81]
      f = tuning.freq(MB::Sound::ArrayInput.new(data: [data]))
      expect(f.sample(3).to_a).to match([be_within(1e-3).of(261.626), be_within(1e-3).of(440), be_within(1e-3).of(880)])
      expect(data.to_a).to eq([60, 69, 81])
    end
  end

  describe 'MB::Sound.tuning' do
    it 'returns and changes the default tuning outside of a session context' do
      expect(MB::Sound.tuning).to equal(MB::Sound::Tuning.default)
      MB::Sound.tuning b4: 480
      expect(MB::Sound::Tuning.default.frequency_of(71)).to eq(480)
      expect(MB::Sound::B4.frequency).to be_within(1e-9).of(480)
    end

    it "uses the current session's tuning" do
      own = MB::Sound::Tuning.new(note: 60, frequency: 256)
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), tuning: own, realtime: false)
      MB::Sound::Session.with_context(session: session) do
        expect(MB::Sound.tuning).to equal(own)
        expect(MB::Sound::C4.frequency).to eq(256)
      end
      expect(MB::Sound::C4.frequency).to be_within(1e-9).of(261.6255653005986)
    ensure
      session&.close
    end

    it 'converts clip note numbers with the tuning' do
      MB::Sound.tuning a4: 432
      hz = MB::Sound.seq(MB::Sound::A4).n4.loop.hz
      expect(hz.sample(10).to_a).to all(be_within(1e-3).of(432))
    end
  end

  it 'describes itself' do
    expect(tuning.to_s).to eq('12-TET, A4 = 440.0 Hz')
  end
end
