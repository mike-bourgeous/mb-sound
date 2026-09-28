RSpec.describe('bin/phase_synth.rb') do
  let(:outfile) { tmp_path('phase_synth_test.flac') }

  it 'can generate an audio file of the expected length' do
    text = `bin/phase_synth.rb #{outfile.shellescape} 300 0 0.1 45 0.1 90 0.1 135 0.1 180 0.1 135 0.1 90 0.1 47 0.1 0 0.1`
    expect($?).to be_success
    expect(text).to include('Index')
    expect(text).to include('47')
    expect(text).to include('42720') # 8 * 4800 + 4800 - 480 (transition)

    info = MB::Sound::FFMPEGInput.parse_info(outfile)
    expect(info[:streams][0][:duration_ts]).to eq(42720)
  end
end
