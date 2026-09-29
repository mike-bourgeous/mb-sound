RSpec.describe('bin/haas_pan.rb') do
  let(:outfile) { tmp_path('haas_pan_test.flac') }

  it 'generates a 2ch output file' do
    text = `bin/haas_pan.rb spec/test_data/arp_a7.flac #{outfile.shellescape} 0 100 0.1 -100 0.2 100 0.3 0 0.4 0`
    result = $?
    raise "ERROR: #{MB::U.remove_ansi(text)}" unless result.success?

    expect(result).to be_success
    expect(text).to include('chunk')
    expect(text).to include('complete')

    in_info = MB::Sound::FFMPEGInput.parse_info('spec/test_data/arp_a7.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info(outfile)

    expect(out_info[:streams][0][:channels]).to eq(2)
    expect(out_info[:streams][0][:duration_ts]).to be_between(in_info[:streams][0][:duration_ts], in_info[:streams][0][:duration_ts] + 100)
  end
end
