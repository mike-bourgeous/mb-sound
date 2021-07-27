RSpec.describe('bin/haas_pan.rb') do
  before(:each) do
    FileUtils.mkdir_p('tmp')
    File.unlink('tmp/haas_pan_test.flac') rescue nil
  end

  it 'generates a 2ch output file' do
    text = `bin/haas_pan.rb sounds/synth0.flac tmp/haas_pan_test.flac 0 100 1 -100 2 100 3 0 4 0`
    result = $?
    raise "ERROR: #{MB::U.remove_ansi(text)}" unless result.success?

    expect(result).to be_success
    expect(text).to include('chunk')
    expect(text).to include('complete')

    in_info = MB::Sound::FFMPEGInput.parse_info('sounds/synth0.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info('tmp/haas_pan_test.flac')

    expect(out_info[:streams][0][:channels]).to eq(2)
    expect(out_info[:streams][0][:duration_ts]).to be_between(in_info[:streams][0][:duration_ts], in_info[:streams][0][:duration_ts] + 100)
  end
end
