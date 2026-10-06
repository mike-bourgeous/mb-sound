RSpec.describe('bin/plot_waveforms.rb') do
  it 'plots all the waveforms' do
    text = `PLOT_TERMINAL=dumb bin/plot_waveforms.rb --width 800 --height 800 2>&1 < /dev/null`
    expect($?).to be_success

    MB::Sound::Tone::WAVE_TYPES.each do |o|
      expect(text).to include(o.to_s.gsub('_', ' '))
    end
  end
end
