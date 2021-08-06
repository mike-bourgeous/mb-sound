RSpec.describe('bin/midi_info.rb') do
  it 'can show MIDI info' do
    text = `bin/midi_info.rb spec/test_data/midi.mid 2>&1`
    expect($?).to be_success

    expect(text).to include('Events')
    expect(text).to include('Unnamed')
  end
end
