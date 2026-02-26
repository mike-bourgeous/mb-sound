RSpec.describe MB::Sound::Tone do
  describe '#generate' do
    it 'can generate triangle wave samples in an NArray' do
      data = 500.hz.triangle.at(0.85).generate(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.median.round(3)).to eq(0.425)
      expect(data.abs.mean.round(3)).to eq(0.425)
    end

    it 'can generate square wave samples in an NArray' do
      data = 500.hz.square.at(0.85).generate(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.mean.round(3)).to eq(0.85)
      expect(data.abs.median.round(3)).to eq(0.85)
    end
  end

  describe '#sample' do
    # TODO: get rid of #generate and move those examples here

    context 'with a duration set' do
      it 'ends after the expected duration exactly' do
        a = 1.hz.square.for(1)
        expect(a.sample(5000)).to be_a(Numo::SFloat)
        expect(a.sample(500)).to be_a(Numo::SFloat)
        expect(a.sample(20000)).to be_a(Numo::SFloat)
        expect(a.sample(500)).to be_a(Numo::SFloat)
        expect(a.sample(22000)).to be_a(Numo::SFloat)
        expect(a.sample(100)).to eq(nil)
      end

      it 'returns a short buffer if the duration does not align with buffer size' do
        a = 1.hz.square.at(1).for(32.0 / 48000.0)
        expect(a.sample(30)).to eq(Numo::SFloat.ones(30))
        expect(a.sample(30)).to eq(Numo::SFloat.ones(2))
        expect(a.sample(30)).to eq(nil)
      end

      it 'returns a short buffer if the duration does not align with sample size' do
        a = 1.hz.square.at(1).for(32.3 / 48000.0)
        expect(a.sample(30)).to eq(Numo::SFloat.ones(30))
        expect(a.sample(30)).to eq(Numo::SFloat.ones(2))
        expect(a.sample(30)).to eq(nil)
      end

      it 'rounds duration to the nearest sample' do
        a = 1.hz.square.at(1).for(0.6 / 48000.0)
        expect(a.sample(30)).to eq(Numo::SFloat.ones(1))
        expect(a.sample(30)).to eq(nil)
      end
    end
  end

  shared_examples_for 'modulation sources' do |method|
    it 'adds another graph node as a source' do
      a = 300.hz
      b = 150.hz.send(method, a)
      expect(b.graph).to include(a)
    end

    it 'changes the sample rate of the upstream source to match' do
      a = 300.hz.at_rate(12345)
      b = 150.hz.at_rate(5432).send(method, a)
      expect(a.sample_rate).to eq(5432)
      expect(b.sample_rate).to eq(5432)
    end

    it 'changes the output' do
      a = 300.hz.at(100)
      b = 150.hz.send(method, a).at(1)
      expect(b.sample(800)).not_to all_be_within(0.2).of_array(150.hz.at(1).sample(800))
    end
  end

  describe '#fm' do
    it_behaves_like 'modulation sources', :fm

    pending 'expected output'
  end

  describe '#log_fm' do
    it_behaves_like 'modulation sources', :log_fm

    pending 'expected output'
  end

  describe '#pm' do
    it_behaves_like 'modulation sources', :pm

    pending 'expected output'
  end

  describe '#for' do
    it 'limits duration' do
      # See also examples for #sample
      expect(1.hz.square.at(1).for(2.0 / 48000.0).sample(4000)).to eq(Numo::SFloat[1, 1])
    end

    it 'resets elapsed timer' do
      t = 1.hz.square.at(1).for(2.0 / 48000.0)
      expect(t.sample(30)).to eq(Numo::SFloat[1, 1])

      t.for(3.0 / 48000.0)

      expect(t.sample(30)).to eq(Numo::SFloat[1, 1, 1])
    end
  end

  describe '#oscillator' do
    it 'returns an Oscillator with the same frequency and range' do
      tone = 222.hz.at(-5.db)
      osc = tone.oscillator
      expect(osc).to be_a(MB::Sound::Oscillator)
      expect(osc.frequency).to eq(tone.frequency)
      expect(osc.range).to eq(-tone.amplitude..tone.amplitude)
    end

    it 'passes a reversed range to the oscillator' do
      tone = 220.hz.at(1..-1)
      osc = tone.oscillator
      expect(osc.range).to eq(1..-1)

      data = osc.sample(48000)
      expect(data.min.round(2)).to eq(-1)
      expect(data.max.round(2)).to eq(1)
      expect(data[0]).to eq(0)
      expect(data[30]).to be < 0 # should go down first instead of up because of reversed range
    end

    it 'passes an asymmetric range to the oscillator' do
      tone = 220.hz.at(3..5)
      osc = tone.oscillator
      expect(osc.range).to eq(3..5)

      data = osc.sample(48000)
      expect(data.min.round(2)).to eq(3)
      expect(data.max.round(2)).to eq(5)
      expect(data[0]).to eq(4)
      expect(data[30]).to be > 4 # should go up first
    end

    it 'passes initial phase to an oscillator' do
      tone = 220.hz.with_phase(180.degrees)
      osc = tone.oscillator
      expect(osc.phase).to eq(180.degrees)

      data = osc.sample(48000)
      expect(data[0].round(8)).to eq(0)
      expect(data[30].round(8)).to be < 0 # should go down first because of phase
    end

    it 'passes sample rate to an oscillator' do
      tone = 220.hz.at_rate(43210)
      osc = tone.oscillator

      expect(osc.advance.round(5)).to eq((2.0 * Math::PI / 43210).round(5))
    end
  end

  describe '#lowpass' do
    it 'returns a Filter' do
      f = 123.hz.at_rate(47999).lowpass(quality: 3)
      expect(f).to be_a(MB::Sound::Filter::Cookbook)
      expect(f.center_frequency).to eq(123)
      expect(f.sample_rate).to eq(47999)
      expect(f.filter_type).to eq(:lowpass)
      expect(f.quality).to eq(3)
    end
  end

  describe '#highpass' do
    it 'returns a Filter' do
      f = 423.hz.at_rate(8000).highpass(quality: 4)
      expect(f).to be_a(MB::Sound::Filter::Cookbook)
      expect(f.center_frequency).to eq(423)
      expect(f.sample_rate).to eq(8000)
      expect(f.filter_type).to eq(:highpass)
      expect(f.quality).to eq(4)
    end
  end

  describe '#peak' do
    it 'returns a Filter' do
      f = 523.hz.at(-5.db).at_rate(32323).peak(octaves: 1.1)
      expect(f).to be_a(MB::Sound::Filter::Cookbook)
      expect(f.center_frequency).to eq(523)
      expect(f.sample_rate).to eq(32323)
      expect(f.filter_type).to eq(:peak)
      expect(f.bandwidth_oct).to eq(1.1)
      expect(f.db_gain.round(4)).to eq(-5)
    end
  end

  describe '#follower' do
    let(:f) { 375.hz.at(1).follower }

    it 'generates a linear velocity-limited signal follower' do
      expect(f).to be_a(MB::Sound::Filter::LinearFollower)
      expect(f.sample_rate).to eq(48000)
      expect(f.max_rise).to eq(375 * 4 / 48000.0)
      expect(f.max_fall).to eq(375 * 4 / 48000.0)
      expect(f.absolute).to eq(false)
    end

    it 'increases the rise and fall rates with frequency' do
      expect(500.hz.follower.max_rise).to be > 250.hz.follower.max_rise
      expect(500.hz.follower.max_fall).to be > 250.hz.follower.max_fall
    end

    it 'increases the rise and fall rates with amplitude' do
      expect(500.hz.at(1).follower.max_rise).to be > 500.hz.at(0.5).follower.max_rise
      expect(500.hz.at(1).follower.max_fall).to be > 500.hz.at(0.5).follower.max_fall
    end

    it 'passes a lower-frequency triangle wave unmodified' do
      data = 50.hz.triangle.at(1).generate(1024)
      expect(MB::M.round(f.process(data), 6)).to eq(MB::M.round(data, 6))
    end

    it 'passes an equal-frequency triangle wave unmodified' do
      data = 375.hz.triangle.at(1).generate(1024)
      expect(MB::M.round(f.process(data), 6)).to eq(MB::M.round(data, 6))
    end

    it 'does not pass an equal-frequency sine wave unmodified' do
      data = 375.hz.sine.at(1).generate(1024)
      expect(MB::M.round(f.process(data), 6)).not_to eq(MB::M.round(data, 6))
    end
  end

  describe '#initialize' do
    it 'can be constructed from a wavelength' do
      expect(MB::Sound::Tone.new(frequency: 343.meters).wavelength).to eq(343.meters)
      expect(MB::Sound::Tone.new(frequency: 30.feet).wavelength).to eq(30.feet)
    end
  end

  describe '#wavelength' do
    it 'returns the wavelength of a sound at sealevel' do
      expect(1.hz.wavelength).to eq(MB::Sound::SPEED_OF_SOUND)
      expect(100.hz.wavelength).to eq(MB::Sound::SPEED_OF_SOUND * 0.01)
    end
  end

  describe '#to_midi' do
    it 'returns a midi note-on message' do
      result = 50.hz.to_midi(channel: 4, velocity: 3)
      expect(result).to be_a(MIDIMessage::NoteOn)
      expect(result.note).to eq(50.hz.to_note.number)
      expect(result.velocity).to eq(3)
      expect(result.channel).to eq(4)
    end
  end

  describe '#at_rate' do
    it 'can change the sample rate of upstream sources' do
      a = 100.hz.at_rate(1234)
      b = 200.hz.at_rate(5678)
      c = 300.hz.at_rate(9101)
      d = 15.constant.at_rate(5151) * c
      e = 150.hz.at_rate(2324).fm(d)
      f = 400.hz.at_rate(1500).fm(a).log_fm(b).pm(e)

      f.at_rate(48001)

      expect(a.sample_rate).to eq(48001)
      expect(b.sample_rate).to eq(48001)
      expect(c.sample_rate).to eq(48001)
      expect(d.sample_rate).to eq(48001)
      expect(e.sample_rate).to eq(48001)
      expect(f.sample_rate).to eq(48001)
    end
  end
end
