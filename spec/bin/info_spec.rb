RSpec.describe('bin/info.rb') do
  it 'can print help' do
    # In a fork (see ForkScript); the next example is the real run
    text, status = fork_script('bin/info.rb', '--help')
    expect(MB::U.remove_ansi(text)).to include('bin/info.rb filename')
    expect(status).to be_success
  end

  it 'can parse a FLAC file' do
    expect(MB::U.remove_ansi(`bin/info.rb sounds/piano0.flac`)).to include(/sample_rate.*48000/)
    expect($?).to be_success
  end
end
