RSpec.describe('bin/plot_waveforms.rb') do
  it 'plots all the waveforms' do
    text = `PLOT_TERMINAL=dumb PLOT_WIDTH=800 PLOT_HEIGHT=800 bin/plot_waveforms.rb 2>&1 < /dev/null`
    expect($?).to be_success
    
    MB::Sound::Oscillator::WAVE_TYPES.each do |o|
      expect(text).to include(o.to_s.gsub('_', ' '))
    end
  end
end
