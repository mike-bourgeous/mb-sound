RSpec.describe('bin/midi_roll.rb', :aggregate_failures) do
  it 'can display a MIDI roll' do
    text = `bin/midi_roll.rb -r 2 -c 100 -n C3 spec/test_data/all_notes.mid 2>&1`
    expect($?).to be_success

    lines = MB::U.remove_ansi(text.strip).lines

    expect(lines.count).to eq(3)
    expect(lines[0]).to include('all_notes.mid')
    expect(lines[1]).to match(/49.*C\u266f3.*\u2517\u2501.*\u251b/)
    expect(lines[2]).to match(/48.*C3.*\u2517\u2501.*\u251b/)
  end

  it 'can display note sustain from the sustain pedal' do
    text = `bin/midi_roll.rb -r 1 -c 50 -n C2 spec/test_data/c2_sustain.mid 2>&1`
    expect($?).to be_success

    lines = MB::U.remove_ansi(text.strip).lines

    expect(lines.count).to eq(2)
    expect(lines[0]).to include('c2_sustain.mid')
    expect(lines[1]).to match(/36.*C2.*\u2517.*\u2501.*\u2539.*╌/)
  end

  it 'can select the range of notes to display' do
    text = `bin/midi_roll.rb -r 1 -c 100 -n B2 spec/test_data/c2_sustain.mid 2>&1`
    expect($?).to be_success
    expect(text).not_to include('┗')

    text = `bin/midi_roll.rb -r 1 -c 100 -n C2 spec/test_data/c2_sustain.mid 2>&1`
    expect($?).to be_success
    expect(text).to include('┗')
  end

  it 'does not allow specifying both -e and -d' do
    text = `bin/midi_roll.rb -e 3 -d 2 2>&1`
    expect($?).not_to be_success

    expect(text).to match(/duration.*both/)
  end

  context 'with each MIDI file in the project' do
    Dir['spec/test_data/**/*.mid', 'sounds/**/*.mid'].each do |midi_file|
      it "can parse #{midi_file}" do
        text = `bin/midi_roll.rb #{midi_file} 2>&1`
        expect($?).to be_success
        expect(text).to include(midi_file)
      end
    end
  end

  context 'with the --channel= parameter' do
    it 'accepts channel -1 for all channels' do
      text = `bin/midi_roll.rb --channel=-1 -n C3 -r 1 spec/test_data/all_notes.mid 2>&1`
      expect($?).to be_success
      expect(text).to include('all channels')
    end

    it 'accepts channel 1' do
      # This tests off-by-one errors in range checking, which is a thing that
      # actually happened.
      text = `bin/midi_roll.rb --channel=1 -n C3 -r 1 spec/test_data/all_notes.mid 2>&1`
      expect($?).to be_success
      expect(text).to include('C3')

      lines = MB::U.remove_ansi(text.strip).lines
      expect(lines.count).to eq(2)

      expect(lines[0]).to include('channel 1')
      expect(lines[1]).to include('C3')
      expect(lines[1]).to match(/┗━*┛/)
    end

    it 'accepts channel 16' do
      text = `bin/midi_roll.rb --channel=16 -n C3 -r 1 spec/test_data/all_notes.mid 2>&1`
      expect($?).to be_success
      expect(text).to include('channel 16')
      expect(text).to include('C3')
      expect(text).not_to include('┛')
    end

    it 'accepts a different channel number to display' do
      text = `bin/midi_roll.rb --channel=2 -n C3 -r 1 spec/test_data/all_notes.mid 2>&1`
      expect($?).to be_success

      lines = MB::U.remove_ansi(text.strip).lines
      expect(lines.count).to eq(2)

      expect(lines[0]).to include('channel 2')
      expect(lines[1]).to include('C3')
      expect(lines[1]).not_to match(/┗━*┛/)
    end

    it 'fails if given an invalid channel number' do
      text = `bin/midi_roll.rb --channel=0 spec/test_data/all_notes.mid 2>&1`
      expect($?).not_to be_success

      expect(text).to include('1 to 16')
      expect(text).not_to include('C3')
    end
  end
end
