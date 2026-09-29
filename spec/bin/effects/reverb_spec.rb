RSpec.describe('bin/effects/reverb.rb') do
  let(:outfile) { tmp_path('reverb_test.flac') }

  it 'can create an output file from an input file' do
    output = `bin/effects/reverb.rb -f -q spec/test_data/arp_a7.flac #{outfile.shellescape} 2>&1`
    expect($?).to be_success, "bin/effects/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info(outfile).dig(:format, :duration)).to be > 2
  end

  it 'can upmix channels' do
    output = `bin/effects/reverb.rb -f -q spec/test_data/arp_a7.flac #{outfile.shellescape} --output-channels 5 2>&1`
    expect($?).to be_success, "bin/effects/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info(outfile).dig(:streams, 0, :channels)).to eq(5)
  end

  it 'can downmix channels' do
    output = `bin/effects/reverb.rb -f -q spec/test_data/arp_a7.flac #{outfile.shellescape} --output-channels 1 2>&1`
    expect($?).to be_success, "bin/effects/reverb.rb failed: #{output}"
    expect(MB::Sound::FFMPEGInput.parse_info(outfile).dig(:streams, 0, :channels)).to eq(1)
  end
end
