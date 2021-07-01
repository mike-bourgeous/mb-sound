RSpec.describe('bin/phase_synth.rb') do
  before(:each) {
    FileUtils.mkdir_p('tmp')
    File.unlink('tmp/phase_synth_test.flac') rescue nil
  }

  it 'can generate an audio file of the expected length' do
    text = `bin/phase_synth.rb tmp/phase_synth_test.flac 300 0 1 45 1 90 1 135 1 180 1 135 1 90 1 47 1 0 1`
    expect($?).to be_success
    expect(text).to include('Index')
    expect(text).to include('47')
    expect(text).to include('431520')

    info = MB::Sound::FFMPEGInput.parse_info('tmp/phase_synth_test.flac')
    expect(info[:streams][0][:duration_ts]).to eq(431520)
  end
end
