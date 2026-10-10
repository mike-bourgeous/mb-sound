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

  # (--highpass: shimmer without a loop highpass grows at low frequencies,
  # see the reverb spec's shimmer note)
  it 'builds the room-size form with modulation and loop processing (the old fdn_reverb.rb options)' do
    output = `bin/effects/reverb.rb --quiet --room-size 0.8 --decay 1.0 --damping 0.7 --mod lush --mod-rate 0.3 --drive 2 --drive-mode fold --crush 10 --shimmer 0.3 --highpass 100 spec/test_data/arp_a7.flac #{outfile.shellescape} 2>&1`
    expect($?).to be_success, output
    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info.dig(:format, :duration)).to be_between(1.0, 3.5)
    expect(info.dig(:streams, 0, :channels)).to eq(2)
  end

  it 'takes the Jot damping design' do
    output = `bin/effects/reverb.rb --quiet -f --room-size 0.5 --decay 0.5 --damping 0.5 --damping-design jot spec/test_data/arp_a7.flac #{outfile.shellescape} 2>&1`
    expect($?).to be_success, output
    expect(File.size(outfile)).to be > 1000
  end

  it 'takes a preset with modulation off and draws its graph' do
    output = `DISPLAY= bin/effects/reverb.rb --quiet -p plate --mod off --diffusion-mod 0.05 spec/test_data/arp_a7.flac #{outfile.shellescape} --graphviz 2>&1`
    expect($?).to be_success, output
    expect(File.size(outfile)).to be > 1000
  end
end
