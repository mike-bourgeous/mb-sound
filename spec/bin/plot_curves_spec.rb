require 'shellwords'

RSpec.describe('bin/plot_curves.rb') do
  # Runs the script in a fork (see ForkScript), or as a real process with
  # +real+ (the terminal plot: a forked child would share the spec
  # process's cached gnuplot pipes, if it has any).
  def run(*args, real: false)
    text, status = run_script('bin/plot_curves.rb', *args, real: real)
    expect(status).to be_success, text
    text
  end

  it 'prints curve tables with options and edge modes' do
    text = run('--print', '--cycles', '4', 'steps', 'bounce', '30')
    expect(text).to match(/^steps\(4\) +0\.000 +0\.250 +0\.250 +0\.500/)
    expect(text).to match(/^bounce\(0\.25, 4\) +0\.000 /)
    expect(text).to match(/^db\(30\.0\) +0\.000 /)

    text = run('--print', '--from', '-1', '--to', '2', '--edges', 'mirror', 'linear')
    expect(text).to match(/^linear +1\.000 +0\.700 +0\.400 +0\.100 +0\.200/)
  end

  it 'lists the names and plots in the terminal' do
    expect(run('--list')).to include('squiggle', 'ease_in_out')
    expect(run('-t', 'elastic', real: true).gsub(/\e\[[0-9;]*m/, '')).to include('elastic(0.3, 3.0)')
  end
end
