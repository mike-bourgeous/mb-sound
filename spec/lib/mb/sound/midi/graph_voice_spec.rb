RSpec.describe(MB::Sound::MIDI::GraphVoice) do
  let (:clock) { MB::Sound::MIDI::MIDIFile::ConstantClock.new }
  let (:midi_file) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid') }
  let (:manager) { MB::Sound::MIDI::Manager.new(jack: nil, input: midi_file) }

  context 'with a block given to the constructor' do
    it 'passes a GraphNode DSL to the block' do
      MB::Sound::MIDI::GraphVoice.new(manager: manager) do |midi|
        expect(midi).to respond_to(:frequency)
        expect(midi).to respond_to(:click)
        midi.hz.tap { |n|
          expect(n).to respond_to(:sample)
        }
      end
    end
  end

  describe(MB::Sound::MIDI::GraphVoice::DslProxy) do
    describe '#channel' do
      it 'raises an error' do
        expect { MB::Sound::MIDI::GraphVoice.new(manager: manager) { |m| m.channel(3) } }.to raise_error(/channel filter/)
      end
    end

    pending '#cc'
    pending '#frequency'
    pending '#hz'
    pending '#number'
    pending '#velocity'
    pending '#bend'
    pending '#env'
    pending '#gate'
    pending '#click'
  end
end
