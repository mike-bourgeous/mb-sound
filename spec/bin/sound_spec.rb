RSpec.describe('bin/sound.rb', :aggregate_failures) do
  it 'can start up and plot a sine wave, shows help, and shows did_you_mean suggestions for errors' do
    raw_text = `printf "plot 123.hz\n123.hz.sqare\nhelp :knobs\nnow\nhelp.knobz\nexit\n" | bin/sound.rb 2>&1`
    result = $?
    output = MB::U.remove_ansi(raw_text)
    expect(result).to be_success

    expect(output).to include('Welcome to mb-sound'), 'shows the welcome text'
    expect(output).to include('play it: help('), 'shows a runnable tip'
    expect(output).to match(/sound\.rb \[\d+\] MB::Sound/), 'displays the right prompt'
    expect(output).to include('123'), 'shows the frequency being plotted'
    expect(output).to match(/└[─┬┴]{20,}/), 'draws the plot axes'
    expect(output).to match(/[⠁-⣿]{3}/), 'draws the sine in Braille'

    # 2026-10-12: since Ruby 3.3 the suggestions are only in
    # Exception#detailed_message, which the console's handler didn't print
    expect(output).to include("undefined method 'sqare'"), 'shows the error'
    expect(output).to match(/undefined method 'sqare' .*\(did you mean square[,?]/), 'shows the suggestion on the same line'

    # Console help (lib/mb/sound/help.rb): help reaches Ruby, not Pry's
    # help command (now pry-help), and pages print as text
    expect(output).to include('Knobs and snapshots  help :knobs'), 'shows a topic page'
    expect(output).not_to include('=> Knobs'), 'prints pages without inspect'
    expect(output).to include('you can'), 'shows now'
    expect(output).to match(/\(did you mean knobs\?\)/), 'suggests topic names'
  end
end
