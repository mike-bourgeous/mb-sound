RSpec.describe('bin/plot_windows.rb') do
  it 'can be called without arguments' do
    text = `PLOT_TERMINAL=dumb PLOT_WIDTH=800 PLOT_HEIGHT=800 bin/plot_windows.rb 2>&1`
    expect($?).to be_success
    expect(text).to match(/----.*\*.*----/m)

    text.gsub!(/[^A-Za-z0-9]+/, ' ')
    MB::Sound::Window.windows.each do |w|
      expect(text).to include(w.window_name)
    end
  end

  it 'can be given a specific window' do
    text = `PLOT_TERMINAL=dumb bin/plot_windows.rb DoubleHann 2>&1`
    expect($?).to be_success
    expect(text).to include('DoubleHann')
    expect(text).not_to include('Rectangular')
  end

  pending 'can override window size and hop'
end
