RSpec.describe('bin/freq_estimate.rb') do
  it 'prints the expected value for a sine wave' do
    text = `bin/freq_estimate.rb sounds/sine/sine_100_1s_mono.flac`
    expect($?).to be_success
    expect(text.strip).to eq('100Hz')
  end

  it 'prints the expected value of a single piano note' do
    # In a fork (see ForkScript); the example above is the real run
    text, status = fork_script('bin/freq_estimate.rb', 'sounds/piano_120hz_b2.flac')
    expect(status).to be_success, text
    expect(text.strip).to eq('120Hz')
  end
end
