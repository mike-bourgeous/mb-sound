RSpec.describe('bin/make_wavetable.rb', aggregate_failures: true) do
  let(:name) { tmp_path('make_wavetable_test.flac') }

  it 'can make a wavetable from a piano note' do
    text = `bin/make_wavetable.rb --quiet sounds/piano_120hz_b2.flac #{name.shellescape} 2>&1`
    expect(MB::U.remove_ansi(text)).to match(/120.*|.*B2/)

    info = MB::Sound::FFMPEGInput.parse_info(name)
    expect(info[:streams][0][:duration_ts]).to eq((48000 / 120) * 10)

    # The slicing details are saved with the table
    t = MB::Sound::Wavetable.from_file(name)
    expect(t.source_info[:frequency]).to be_within(2).of(120)
    expect(t.source_info[:note_name]).to match(/B2|A#2/)
    expect(t.frame_count).to eq(10)
  end

  it 'can change the table size' do
    text = `bin/make_wavetable.rb --quiet sounds/piano_120hz_b2.flac #{name.shellescape} --size=30 2>&1`
    expect(MB::U.remove_ansi(text)).to match(/120.*|.*B2/)

    info = MB::Sound::FFMPEGInput.parse_info(name)
    expect(info[:streams][0][:duration_ts]).to eq((48000 / 120) * 30)
  end
end
