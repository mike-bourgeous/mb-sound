RSpec.describe('bin/phase_synth.rb') do
  let(:outfile) { tmp_path('phase_synth_test.flac') }

  it 'can generate an audio file of the expected length' do
    text = `bin/phase_synth.rb #{outfile.shellescape} 300 0 1 45 1 90 1 135 1 180 1 135 1 90 1 47 1 0 1`
    expect($?).to be_success
    expect(text).to include('Index')
    expect(text).to include('47')
    expect(text).to include('431520')

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to eq(431520)
  end
end
