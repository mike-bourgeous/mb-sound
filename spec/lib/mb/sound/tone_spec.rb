RSpec.describe MB::Sound::Tone do
  describe '#generate' do
    it 'can generate triangle wave samples in an NArray' do
      data = 500.hz.atriangle.at(0.85).sample(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.median.round(3)).to eq(0.425)
      expect(data.abs.mean.round(3)).to eq(0.425)
    end

    it 'can generate square wave samples in an NArray' do
      data = 500.hz.asquare.at(0.85).sample(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.mean.round(3)).to eq(0.85)
      expect(data.abs.median.round(3)).to eq(0.85)
    end
  end

  describe '#sample' do
    # TODO: get rid of #generate and move those examples here

    it 'plays forever' do
      a = 1.hz.square.at(1)
      10.times { expect(a.sample(24000)).to be_a(Numo::SFloat).and have_attributes(length: 24000) }
    end

    it 'returns nil for an empty request' do
      expect(1.hz.sample(0)).to eq(nil)
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

    it 'rejects the node itself' do
      a = 300.hz.sine
      expect { a.send(method, a) }.to raise_error(/Cyclic modulation/)
    end

    it 'rejects loops with the node' do
      a = 300.hz.sine
      b = a + 150.hz
      expect { a.send(method, b) }.to raise_error(/Cyclic modulation/)
    end

    it 'rejects loops through a Tee' do
      a = 300.hz.sine
      b = a.get_sampler * 2
      a.get_sampler # makes a Tee
      expect { a.send(method, b) }.to raise_error(/Cyclic modulation/)
    end

    it 'accepts a node that already feeds the tone another way (no cycle)' do
      lfo = 3.hz.lfo.at(10)
      a = MB::Sound::Tone.new(frequency: lfo + 300)
      expect { a.send(method, lfo) }.not_to raise_error
      expect(a.graph).to include(lfo)
      expect(a.sample(800)).to be_a(Numo::SFloat)
    end
  end

  describe 'cycle check' do
    it 'accepts a shared trigger feeding both the frequency and the reset input' do
      trig = 0.constant
      lfo = 5.hz.lfo.reset(trig)
      a = MB::Sound::Tone.new(wave_type: :ramp, frequency: lfo * 10 + 300)
      expect { a.reset(trig) }.not_to raise_error
      expect(a.sample(480)).to be_a(Numo::SFloat)
    end

    it 'still rejects a reset input that depends on the tone' do
      a = 300.hz.saw
      expect { a.reset(a.get_sampler * 1) }.to raise_error(/Cyclic modulation/)
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

  describe 'configuration' do
    it 'is fixed once the tone plays' do
      t = 220.hz.ramp.at(0.5)
      t.sample(10)
      [
        -> { t.at(0.2) }, -> { t.square }, -> { t.with_phase(1) }, -> { t.fm(110.hz) },
        -> { t.pm(110.hz) }, -> { t.pwm(0.3) }, -> { t.sync(ratio: 2) }, -> { t.reset(nil) },
        -> { t.free }, -> { t.rnd }, -> { t.lfo }, -> { t.noise }, -> { t.seed = 3 },
      ].each do |change|
        expect(&change).to raise_error(FrozenError, /already playing/)
      end
    end

    it 'warns and keeps the tone unchanged in live mode' do
      t = 220.hz.ramp.at(0.5)
      before = t.sample(100).dup
      MB::Sound.live = true
      expect { expect(t.at(0.1)).to equal(t) }.to output(/FrozenError.*already playing.*live mode: ignored/).to_stderr
      expect { t.square }.to output(/live mode/).to_stderr

      u = 220.hz.ramp.at(0.5)
      u.sample(100)
      expect(t.sample(100)).to eq(u.sample(100))
      expect(before.length).to eq(100)
    ensure
      MB::Sound.live = false
    end

    it 'still accepts or_at and sample rate changes after playing starts' do
      t = 220.hz.ramp.at(0.5)
      t.sample(10)
      expect(t.or_at(1).range).to eq(-0.5..0.5)
      expect { t.at_rate(96000) }.not_to raise_error
      expect(t.advance).to eq(1.0 / 96000)
    end

    it 'picks up changes made after the state was inspected' do
      t = 220.hz.ramp
      expect(t.phi).to eq(0)
      t.with_phase(Math::PI / 2)
      expect(t.phi).to be_within(1e-12).of(Math::PI / 2)
    end
  end

  describe 'as an oscillator' do
    it 'keeps its frequency and range' do
      tone = 222.hz.at(-5.db)
      expect(tone.frequency).to eq(222)
      expect(tone.range).to eq(-tone.amplitude..tone.amplitude)
    end

    it 'plays a reversed range' do
      tone = 220.hz.at(1..-1)
      expect(tone.range).to eq(1..-1)

      data = tone.sample(48000)
      expect(data.min.round(2)).to eq(-1)
      expect(data.max.round(2)).to eq(1)
      expect(data[0]).to eq(0)
      expect(data[30]).to be < 0 # should go down first instead of up because of reversed range
    end

    it 'plays an asymmetric range' do
      tone = 220.hz.at(3..5)
      expect(tone.range).to eq(3..5)

      data = tone.sample(48000)
      expect(data.min.round(2)).to eq(3)
      expect(data.max.round(2)).to eq(5)
      expect(data[0]).to eq(4)
      expect(data[30]).to be > 4 # should go up first
    end

    it 'starts at its initial phase' do
      tone = 220.hz.with_phase(180.degrees)
      expect(tone.phase).to eq(180.degrees)

      data = tone.sample(48000)
      expect(data[0].round(8)).to eq(0)
      expect(data[30].round(8)).to be < 0 # should go down first because of phase
    end

    it 'advances its phase at its sample rate' do
      tone = 220.hz.at_rate(43210).tone
      expect(tone.advance.round(12)).to eq((1.0 / 43210).round(12))
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
      data = 50.hz.triangle.at(1).sample(1024)
      expect(MB::M.round(f.process(data), 6)).to eq(MB::M.round(data, 6))
    end

    it 'passes an equal-frequency triangle wave unmodified' do
      data = 375.hz.triangle.at(1).sample(1024)
      expect(MB::M.round(f.process(data), 6)).to eq(MB::M.round(data, 6))
    end

    it 'does not pass an equal-frequency sine wave unmodified' do
      data = 375.hz.sine.at(1).sample(1024)
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
    it 'returns a MIDI note-on event' do
      result = 50.hz.to_midi(channel: 4, velocity: 3)
      expect(result).to be_a(MB::Sound::MIDI::Event)
      expect(result.type).to eq(:note_on)
      expect(result.note).to eq(50.hz.to_note.number.round)
      expect(result.raw).to eq(3)
      expect(result.channel).to eq(4)
      expect(result.bytes.bytes).to eq([0x94, 50.hz.to_note.number.round, 3])
    end

    it 'defaults to velocity 64 on channel 0, for Notes and Pitches too' do
      expect(MB::Sound::C4.to_midi.bytes.bytes).to eq([0x90, 60, 64])
      expect(440.hz.to_midi.bytes.bytes).to eq([0x90, 69, 64])
      expect(MB::Sound::A4.to_midi(velocity: 127, channel: 15).bytes.bytes).to eq([0x9f, 69, 127])
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

    it 'keeps the pitch of a tone with #noise after its oscillator exists' do
      # Count rising zero crossings over one second at each rate
      cycles = ->(tone, rate) {
        data = Array.new(10) { tone.sample(rate / 10).dup }.reduce(&:concatenate)
        ((data[0...-1] < 0) & (data[1..] >= 0)).count_true
      }

      t = 200.hz.noise(0.000007).at(1)
      t.sample(10)
      t.at_rate(96000)
      t.sample(10)

      # Was 267 (the noise's random advance no longer centered)
      expect(cycles.(t, 96000)).to be_within(3).of(200)
    end
  end
end
