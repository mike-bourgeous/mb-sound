RSpec.describe('bin/reverb.rb') do
  before do
    FileUtils.mkdir_p('tmp/')
  end

  it 'can create an output file from an input file' do
    output = `bin/reverb.rb -f -q sounds/piano0.flac tmp/reverb_test.flac 2>&1`
    expect($?).to be_success, "bin/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info('tmp/reverb_test.flac').dig(:format, :duration)).to be > 2
  end

  it 'can upmix channels' do
    output = `bin/reverb.rb -f -q sounds/piano0.flac tmp/reverb_upmix_test.flac --output-channels 5 2>&1`
    expect($?).to be_success, "bin/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info('tmp/reverb_upmix_test.flac').dig(:streams, 0, :channels)).to eq(5)
  end

  it 'can downmix channels' do
    output = `bin/reverb.rb -f -q sounds/piano0.flac tmp/reverb_downmix_test.flac --output-channels 1 2>&1`
    expect($?).to be_success, "bin/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info('tmp/reverb_downmix_test.flac').dig(:streams, 0, :channels)).to eq(1)
  end
end
