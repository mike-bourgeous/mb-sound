RSpec.describe('bin/sound.rb', :aggregate_failures) do
  it 'can start up and plot a sine wave' do
    raw_text = `printf "plot 123.hz\nexit\n" | bin/sound.rb`
    result = $?
    output = MB::U.remove_ansi(raw_text)
    expect(result).to be_success

    expect(output).to include('Welcome to the'), 'shows the welcome text'
    expect(output).to include('sound.rb MB::Sound'), 'displays the right prompt'
    expect(output).to include('123'), 'shows the frequency being plotted'
    expect(output).to match(/└[─┬┴]{20,}/), 'draws the plot axes'
    expect(output).to match(/[\u2801-\u28ff]{3}/), 'draws the sine in Braille'
  end
end
