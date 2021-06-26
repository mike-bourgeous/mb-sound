RSpec.describe('bin/matrix_process.rb') do
  before(:each) do
    FileUtils.mkdir_p('tmp')
    File.unlink('tmp/matrix_process_test.flac') rescue nil
  end

  it 'can convert a 2ch file to a 4ch file' do
    text = `bin/matrix_process.rb sounds/synth0.flac matrices/hafler.yml tmp/matrix_process_test.flac`
    expect($?).to be_success
    expect(text).to include('Success')

    in_info = MB::Sound::FFMPEGInput.parse_info('sounds/synth0.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info('tmp/matrix_process_test.flac')

    expect(out_info[:streams][0][:channels]).to eq(4)
    expect(out_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])
  end
end
