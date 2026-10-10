require 'shellwords'

RSpec.describe('bin/synths/filter_ping.rb') do
  let (:audio_file) { tmp_path('filter_ping.flac') }
  let (:midi_file) { 'spec/test_data/fast_note_velocity.mid' }

  shared_examples_for :synthesizers do
    it 'generates an audio file from a MIDI file' do
      expect(output).not_to be_empty
      expect($?).to be_success

      info = MB::Sound::FFMPEGInput.parse_info(audio_file)

      # Input MIDI is 1.2 seconds, the pings ring until ~1.85 seconds, and
      # the runner stops after a second of quiet
      expect(info[:streams][0][:duration]).to be_between(2.5, 4)
    end
  end

  context 'with positional arguments for files' do
    let (:output) { `bin/synths/filter_ping.rb #{midi_file.shellescape} #{audio_file.shellescape}` }

    it_behaves_like :synthesizers
  end

  context 'with flags for files' do
    # In a fork (see ForkScript); the context above is the real run
    let (:output) {
      text, status = fork_script('bin/synths/filter_ping.rb', '-i', midi_file, '--output', audio_file)
      expect(status).to be_success, text
      text
    }
    it_behaves_like :synthesizers
  end
end
