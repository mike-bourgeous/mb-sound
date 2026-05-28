require 'shellwords'

RSpec.describe('bin/synths/filter_ping.rb') do
  let (:audio_file) { 'tmp/filter_ping.flac' }
  let (:midi_file) { 'spec/test_data/fast_note_velocity.mid' }

  before do
    FileUtils.mkdir_p('tmp/')
    File.unlink(audio_file) if File.exist?(audio_file)
  end

  it 'can generate an audio file from a MIDI file' do
    output = `bin/synths/filter_ping.rb #{midi_file.shellescape} #{audio_file.shellescape}`
    result = $?

    expect(result).to be_success
    
    info = MB::Sound::FFMPEGInput.parse_info(audio_file)

    # Input MIDI is 1.2 seconds, MIDIFile adds 5 seconds
    expect(info[:streams][0][:duration]).to be_between(6, 7)
  end
end
