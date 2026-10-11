RSpec.describe('bin/plot_windows.rb') do
  it 'can be called without arguments' do
    text = `PLOT_WIDTH=300 PLOT_HEIGHT=150 bin/plot_windows.rb 2>&1`
    expect($?).to be_success, text
    text = MB::U.remove_ansi(text)
    expect(text).to match(/└[─┬┴]{10,}/)
    expect(text.lines.count { |l| l.match?(/└[─┬┴]{10,}/) }).to eq(12) # one row of 7 plots per window

    MB::Sound::Window.windows.each do |w|
      expect(text).to include("#{w.window_name} dft")
    end
  end

  it 'can be given a specific window' do
    text, status = run_script('bin/plot_windows.rb', 'DoubleHann', env: { 'PLOT_WIDTH' => '160', 'PLOT_HEIGHT' => '40' })
    expect(status).to be_success, text
    expect(text).to include('DoubleHann')
    expect(text).not_to include('Rectangular')
  end

  pending 'can override window size and hop'
end
