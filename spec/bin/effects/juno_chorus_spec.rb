RSpec.describe('bin/effects/juno_chorus.rb') do
  let(:outfile) { tmp_path('juno_chorus_output.flac') }

  it 'renders a --bbd file chorus that ends soon after the input (hiss stops)' do
    output = `bin/effects/juno_chorus.rb --quiet --mode lush --bbd --mix 0.5 spec/test_data/arp_a7.flac #{outfile.shellescape} 2>&1`
    expect($?).to be_success
    expect(output).to include(outfile)

    # 0.4 s of input, the delay tail, and the runner's 1 s of quiet (the
    # hiss used to run to the 10 s tail limit)
    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    seconds = info[:streams][0][:duration_ts].to_f / 48000
    expect(seconds).to be_between(1.2, 2.0)

    data = MB::Sound.read(outfile)
    expect(data.length).to eq(2)
    expect(data[0].abs.max).to be > 0.1
  end
end
