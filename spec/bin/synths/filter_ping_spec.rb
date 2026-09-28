require 'shellwords'

RSpec.describe('bin/synths/filter_ping.rb') do
  let (:audio_file) { 'tmp/filter_ping.flac' }
  let (:midi_file) { 'spec/test_data/fast_note_velocity.mid' }

  before do
    FileUtils.mkdir_p('tmp/')
    File.unlink(audio_file) if File.exist?(audio_file)
  end

  shared_examples_for :synthesizers do
    it 'generates an audio file from a MIDI file' do
      expect(output).not_to be_empty
      expect($?).to be_success

      info = MB::Sound::FFMPEGInput.parse_info(audio_file)

      # Input MIDI is 1.2 seconds, MIDIFile adds 5 seconds
      expect(info[:streams][0][:duration]).to be_between(6, 7)
    end
  end

  context 'with positional arguments for files' do
    let (:output) { `bin/synths/filter_ping.rb #{midi_file.shellescape} #{audio_file.shellescape}` }

    it_behaves_like :synthesizers
  end

  context 'with flags for files' do
    let (:output) { `bin/synths/filter_ping.rb -i #{midi_file.shellescape} --output #{audio_file.shellescape}` }
    it_behaves_like :synthesizers
  end
end
