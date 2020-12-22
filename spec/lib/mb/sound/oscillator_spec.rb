RSpec.describe MB::Sound::Oscillator do
  describe '#oscillator' do
    it 'returns expected sine wave values for given phases' do
      lfo = MB::Sound::Oscillator.new(:sine)
      expect(lfo.oscillator(0).round(6)).to eq(0)
      expect(lfo.oscillator(0.25 * Math::PI).round(6)).to eq((0.5 ** 0.5).round(6))
      expect(lfo.oscillator(0.5 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(Math::PI).round(6)).to eq(0)
      expect(lfo.oscillator(1.25 * Math::PI).round(6)).to eq(-(0.5 ** 0.5).round(6))
      expect(lfo.oscillator(1.5 * Math::PI).round(6)).to eq(-1)
    end

    it 'returns expected triangle wave values for given phases' do
      lfo = MB::Sound::Oscillator.new(:triangle)
      expect(lfo.oscillator(0).round(6)).to eq(0)
      expect(lfo.oscillator(0.125 * Math::PI).round(6)).to eq(0.25)
      expect(lfo.oscillator(0.25 * Math::PI).round(6)).to eq(0.5)
      expect(lfo.oscillator(0.5 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(0.75 * Math::PI).round(6)).to eq(0.5)
      expect(lfo.oscillator(Math::PI).round(6)).to eq(0)
      expect(lfo.oscillator(1.25 * Math::PI).round(6)).to eq(-0.5)
      expect(lfo.oscillator(1.5 * Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.75 * Math::PI).round(6)).to eq(-0.5)
      expect(lfo.oscillator(1.875 * Math::PI).round(6)).to eq(-0.25)
    end

    it 'returns expected ramp wave values for given phases' do
      lfo = MB::Sound::Oscillator.new(:ramp)
      expect(lfo.oscillator(0).round(6)).to eq(0)
      expect(lfo.oscillator(0.125 * Math::PI).round(6)).to eq(0.125)
      expect(lfo.oscillator(0.25 * Math::PI).round(6)).to eq(0.25)
      expect(lfo.oscillator(0.5 * Math::PI).round(6)).to eq(0.5)
      expect(lfo.oscillator(0.75 * Math::PI).round(6)).to eq(0.75)
      expect(lfo.oscillator(0.999 * Math::PI).round(6)).to eq(0.999)
      expect(lfo.oscillator(Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.25 * Math::PI).round(6)).to eq(-0.75)
      expect(lfo.oscillator(1.5 * Math::PI).round(6)).to eq(-0.5)
      expect(lfo.oscillator(1.875 * Math::PI).round(6)).to eq(-0.125)
      expect(lfo.oscillator(1.999 * Math::PI).round(6)).to eq(-0.001)
    end

    it 'returns expected square wave values for given phases' do
      lfo = MB::Sound::Oscillator.new(:square)
      expect(lfo.oscillator(0).round(6)).to eq(1)
      expect(lfo.oscillator(0.125 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(0.25 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(0.5 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(0.75 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.25 * Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.5 * Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.875 * Math::PI).round(6)).to eq(-1)
    end

    it 'includes pre_power' do
      lfo = MB::Sound::Oscillator.new(:triangle, pre_power: 0.5)

      expect(lfo.oscillator(0).round(6)).to eq(0)
      expect(lfo.oscillator(0.125 * Math::PI).round(6)).to eq((0.25 ** 0.5).round(6))
      expect(lfo.oscillator(0.25 * Math::PI).round(6)).to eq((0.5 ** 0.5).round(6))
      expect(lfo.oscillator(0.5 * Math::PI).round(6)).to eq(1)
      expect(lfo.oscillator(0.75 * Math::PI).round(6)).to eq((0.5 ** 0.5).round(6))
      expect(lfo.oscillator(Math::PI).round(6)).to eq(0)
      expect(lfo.oscillator(1.25 * Math::PI).round(6)).to eq(-(0.5 ** 0.5).round(6))
      expect(lfo.oscillator(1.5 * Math::PI).round(6)).to eq(-1)
      expect(lfo.oscillator(1.75 * Math::PI).round(6)).to eq(-(0.5 ** 0.5).round(6))
      expect(lfo.oscillator(1.875 * Math::PI).round(6)).to eq(-(0.25 ** 0.5).round(6))
    end

    it 'clamps values with negative pre_power' do
      lfo = MB::Sound::Oscillator.new(:triangle, pre_power: -100)
      expect(lfo.oscillator(0.0001).round(6)).to eq(1.0)
    end
  end

  describe '#sample' do
    it 'returns a different value on subsequent calls' do
      lfo = MB::Sound::Oscillator.new(:sine)
      result = lfo.sample
      5.times do
        old_result = result
        result = lfo.sample
        expect(result).not_to eq(old_result)
      end
    end

    it 'returns the expected sequence for a faster advancing sine wave' do
      lfo = MB::Sound::Oscillator.new(:sine, advance: 0.25 * Math::PI)
      expect(lfo.sample.round(6)).to eq(0)
      expect(lfo.sample.round(6)).to eq((0.5 ** 0.5).round(6))
      expect(lfo.sample.round(6)).to eq(1)
      expect(lfo.sample.round(6)).to eq((0.5 ** 0.5).round(6))
      expect(lfo.sample.round(6)).to eq(0)
      expect(lfo.sample.round(6)).to eq(-(0.5 ** 0.5).round(6))
      expect(lfo.sample.round(6)).to eq(-1)
      expect(lfo.sample.round(6)).to eq(-(0.5 ** 0.5).round(6))
      expect(lfo.sample.round(6)).to eq(0)
    end

    it 'returns the expected sequence for a faster advancing triangle wave' do
      lfo = MB::Sound::Oscillator.new(:triangle, advance: 0.25 * Math::PI)
      expect(lfo.sample.round(6)).to eq(0)
      expect(lfo.sample.round(6)).to eq(0.5)
      expect(lfo.sample.round(6)).to eq(1)
      expect(lfo.sample.round(6)).to eq(0.5)
      expect(lfo.sample.round(6)).to eq(0)
      expect(lfo.sample.round(6)).to eq(-0.5)
      expect(lfo.sample.round(6)).to eq(-1)
      expect(lfo.sample.round(6)).to eq(-0.5)
      expect(lfo.sample.round(6)).to eq(0)
    end

    it 'scales to a different range' do
      lfo = MB::Sound::Oscillator.new(:triangle, range: 2..5, advance: 0.25 * Math::PI)
      expect(lfo.sample.round(6)).to eq(3.5)
      expect(lfo.sample.round(6)).to eq(4.25)
      expect(lfo.sample.round(6)).to eq(5)
      expect(lfo.sample.round(6)).to eq(4.25)
      expect(lfo.sample.round(6)).to eq(3.5)
      expect(lfo.sample.round(6)).to eq(2.75)
      expect(lfo.sample.round(6)).to eq(2)
      expect(lfo.sample.round(6)).to eq(2.75)
      expect(lfo.sample.round(6)).to eq(3.5)
    end

    it 'applies post_power after scaling' do
      lfo = MB::Sound::Oscillator.new(:triangle, range: 2..4, post_power: 2, advance: 0.5 * Math::PI)
      expect(lfo.sample.round(6)).to eq(9)
      expect(lfo.sample.round(6)).to eq(16)
      expect(lfo.sample.round(6)).to eq(9)
      expect(lfo.sample.round(6)).to eq(4)
      expect(lfo.sample.round(6)).to eq(9)
    end

    it 'takes phase into account' do
      lfo = MB::Sound::Oscillator.new(:square, phase: 0.9 * Math::PI, advance: 0.2 * Math::PI)
      expect(lfo.sample).to eq(1)
      expect(lfo.sample).to eq(-1)
      lfo = MB::Sound::Oscillator.new(:square, phase: 1.5 * Math::PI, advance: Math::PI)
      expect(lfo.sample).to eq(-1)
      expect(lfo.sample).to eq(1)
    end

    it 'can generate more than one sample' do
      oscil = MB::Sound::Oscillator.new(:sine, frequency: 100, advance: Math::PI / 24000)
      data = oscil.sample(48000)
      expect(data.length).to eq(48000)
      expect(data.min.round(3)).to eq(-1)
      expect(data.max.round(3)).to eq(1)
      expect(data.sum.round(2)).to eq(0)
    end
  end

  describe '#handle_midi' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0, range: 0..0)
    }

    context 'with a note on event' do
      it 'changes frequency' do
        expect(oscil.frequency).to eq(0)
        oscil.handle_midi(MIDIMessage::NoteOn.new(0, 25, 0))
        expect(oscil.frequency).to eq(MB::Sound::Note.new(25).frequency)
        oscil.handle_midi(MIDIMessage::NoteOn.new(0, 75, 0))
        expect(oscil.frequency).to eq(MB::Sound::Note.new(75).frequency)
      end

      it 'changes amplitude' do
        expect(oscil.range).to eq(0..0)
        oscil.handle_midi(MIDIMessage::NoteOn.new(0, 25, 127))
        expect(oscil.range).to eq(-0.51..0.51)
      end
    end

    context 'with a note off event' do
      it 'does not change frequency' do
        oscil.handle_midi(MIDIMessage::NoteOff.new(0, 25, 0))
        expect(oscil.frequency).to eq(0)
      end

      it 'silences the oscillator for a matching event' do
      oscil.handle_midi(MIDIMessage::NoteOn.new(0, 25, 0))
      oscil.handle_midi(MIDIMessage::NoteOff.new(0, 24, 0))
      end

      it 'does not silence the oscillator for a non-matching event' do
        oscil.handle_midi(MIDIMessage::NoteOn.new(0, 25, 0))
        oscil.handle_midi(MIDIMessage::NoteOff.new(0, 24, 0))
        expect(oscil.range).to eq(-0.01..0.01)
      end
    end

    context 'wtih a control change' do
      it 'changes oscillator power for the mod wheel' do
        oscil.handle_midi(MIDIMessage::ControlChange.new(0, 1, 0))
        expect(oscil.post_power.round(4)).to eq(1.0)
        oscil.handle_midi(MIDIMessage::ControlChange.new(0, 1, 127))
        expect(oscil.post_power.round(4)).to eq(0.1)
      end
    end
  end
end
