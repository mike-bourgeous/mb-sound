RSpec.describe('bin/matrix_process.rb') do
  before(:each) do
    FileUtils.mkdir_p('tmp')
    File.unlink('tmp/matrix_process_test.flac') rescue nil
    File.unlink('tmp/matrix_process_qs.flac') rescue nil
    File.unlink('tmp/matrix_process_qs_enc.flac') rescue nil
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

  it 'can decode and re-encode using an included complex-valued matrix' do
    text = `bin/matrix_process.rb --decode sounds/synth0.flac qs.yml tmp/matrix_process_qs.flac`
    expect($?).to be_success
    expect(text).to include('included matrix')
    expect(text).to include('Success')

    in_info = MB::Sound::FFMPEGInput.parse_info('sounds/synth0.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info('tmp/matrix_process_qs.flac')

    expect(out_info[:streams][0][:channels]).to eq(4)
    expect(out_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])

    text = `bin/matrix_process.rb tmp/matrix_process_qs.flac qs.yml tmp/matrix_process_qs_enc.flac`
    expect($?).to be_success
    expect(text).to include('included matrix')
    expect(text).to include('Success')

    enc_info = MB::Sound::FFMPEGInput.parse_info('tmp/matrix_process_qs_enc.flac')

    expect(enc_info[:streams][0][:channels]).to eq(2)
    expect(enc_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])
  end

  it 'lists included matrices when given the --list flag' do
    text = `bin/matrix_process.rb --list 2>&1`
    expect($?).not_to be_success
    expect(text).to include('Built-in matrices')
    expect(text).to include('hafler.yml')
    expect(text).to include('qs.yml')
    expect(text).to include('sq.yml')
  end
end
