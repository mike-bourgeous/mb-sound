RSpec.describe('bin/plot_waveforms.rb') do
  it 'plots all the waveforms' do
    text = `PLOT_WIDTH=240 PLOT_HEIGHT=150 bin/plot_waveforms.rb 2>&1 < /dev/null`
    expect($?).to be_success, text

    text = MB::U.remove_ansi(text)
    MB::Sound::Tone::WAVE_TYPES.each do |o|
      expect(text).to include("#{o.to_s.gsub('_', ' ')} time", "#{o.to_s.gsub('_', ' ')} freq")
    end
  end

  it 'saves the plots as SVG' do
    path = tmp_path('waveforms.svg')
    text, status = run_script('bin/plot_waveforms.rb', '-S', path, '--width', '1200', '--height', '600', 'sine', 'square')
    expect(status).to be_success, text
    svg = File.read(path)
    expect(svg).to start_with('<svg').and include('sine time', 'square freq')
  end
end
