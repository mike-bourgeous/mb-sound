RSpec.describe(MB::Sound::MIDI::GraphVoice, aggregate_failures: true) do
  let (:filename) { 'spec/test_data/midi.mid' }
  let (:clock) { MB::Sound::GraphNode::MidiDsl::DslClock.new }
  let (:midi_file) { MB::Sound::MIDI::MIDIFile.new(filename, clock: clock) }
  let (:manager) { MB::Sound::MIDI::Manager.new(jack: nil, input: midi_file) }
  let (:voice_count) { 1 }
  let (:voice) { proc { MB::Sound::MIDI::GraphVoice.new(manager: manager) { 0.constant } } }
  let (:voices) { Array.new(voice_count, &voice) }
  let (:pool) { MB::Sound::MIDI::VoicePool.new(manager, voices) }

  before do
    clock.dsl = voices.first.dsl_proxy
  end

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
    # Tests for per-voice/note-specific events
    shared_examples_for :a_single_voice do
      let(:voice_count) { 16 }

      it 'responds only to notes targeted at each voice' do
        data = pool.multi_sample_individual(800, 180)
        expect(data.map(&:to_a).uniq.length).to eq(voice_count)
      end
    end

    # Tests for channel-wide events (CC, pitch bend)
    shared_examples_for :channel_wide_controls do
      let(:voice_count) { 16 }

      it 'responds regardless of voice allocation' do
        data = pool.multi_sample_individual(800, 180)
        expect(data.map(&:to_a).uniq.length).to eq(1)
      end
    end

    describe '#channel' do
      it 'raises an error' do
        expect { MB::Sound::MIDI::GraphVoice.new(manager: manager) { |m| m.channel(3) } }.to raise_error(/channel filter/)
      end
    end

    describe '#cc' do
      let (:filename) { 'spec/test_data/mod_wheel.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.cc(1)
          }
        }
      }

      it 'responds to control changes' do
        expect(pool.sample(800).sum).to eq(0)
        expect(pool.multi_sample(800, 600).sum).to be > 0
      end

      it_behaves_like :channel_wide_controls
    end

    describe '#bend' do
      let (:filename) { 'spec/test_data/pitch_bend.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.bend(range: -1..1)
          }
        }
      }

      it 'returns pitch bend' do
        data = pool.multi_sample(800, 360)
        expect(data.min).to be < -0.9
        expect(data.max).to be > 0.9
      end

      it_behaves_like :channel_wide_controls
    end

    describe '#frequency' do
      let (:filename) { 'spec/test_data/all_notes.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.frequency
          }
        }
      }

      it 'produces the frequency of notes' do
        data = pool.multi_sample(800, 600)
        expect(data.min).to be < 440
        expect(data.max).to be > 440
      end

      it_behaves_like :a_single_voice
    end

    describe '#hz' do
      let (:filename) { 'spec/test_data/all_notes.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.hz
          }
        }
      }

      it 'creates an oscillator' do
        spectra = Array.new(300) { MB::Sound.real_fft(pool.sample(800)) }
        indices = spectra.map { |s| s.abs.max_index }
        expect(indices.min).to be < 10
        expect(indices.max).to be > 100
        expect(indices.last).to be > 100
      end

      it_behaves_like :a_single_voice
    end

    describe '#number' do
      let (:filename) { 'spec/test_data/all_notes.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.number
          }
        }
      }

      it 'returns note number' do
        data = pool.multi_sample(800, 360)
        expect(data.min).to eq(0)
        expect(data.max).to eq(127)
      end

      it_behaves_like :a_single_voice
    end

    describe '#velocity' do
      let (:filename) { 'spec/test_data/fast_note_velocity.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.velocity(range: 0..127)
          }
        }
      }

      it 'returns note velocity' do
        data = pool.multi_sample(800, 360)
        expect(data.min).to be < 5
        expect(data.max).to be > 100
      end

      it_behaves_like :a_single_voice
    end

    describe '#gate' do
      let (:filename) { 'spec/test_data/fast_note_velocity.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.gate
          }
        }
      }

      it 'returns scaled velocity when a note is held' do
        data = pool.multi_sample(800, 360)
        expect(data.min).to be_between(0.0, 0.05)
        expect(data.max).to be_between(0.95, 1.0)
      end

      it_behaves_like :a_single_voice
    end

    describe '#click' do
      let (:filename) { 'spec/test_data/fast_note_velocity.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.click
          }
        }
      }

      it 'produces a velocity-scaled impulse when a note starts' do
        data = pool.multi_sample(800, 30)
        expect(data.max).to be > 0.95
        expect(data.min).to eq(0)
        expect(data.mean).to be_between(0, 0.1)
      end

      it_behaves_like :a_single_voice
    end

    describe '#env' do
      let (:filename) { 'spec/test_data/fast_note_velocity.mid' }

      let (:voice) {
        proc {
          MB::Sound::MIDI::GraphVoice.new(manager: manager) { |midi|
            midi.env(0.1, 0.1, 0, 0)
          }
        }
      }

      it 'returns envelope values' do
        data = pool.multi_sample(800, 360)
        expect(data.max).to be > 0.3
        expect(data.min).to be < 0.1
      end

      it_behaves_like :a_single_voice
    end
  end
end
