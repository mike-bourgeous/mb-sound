RSpec.describe('bin/reverb.rb') do
  before do
    FileUtils.mkdir_p('tmp/')
    File.unlink('tmp/reverb_test.flac') rescue nil
  end

  it 'can create an output file from an input file' do
    output = `bin/reverb.rb -f -q sounds/piano0.flac tmp/reverb_test.flac 2>&1`
    expect($?).to be_success(), "bin/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info('tmp/reverb_test.flac').dig(:format, :duration)).to be > 2
  end
end
