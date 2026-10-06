RSpec.describe(MB::Sound::LiveMethods) do
  after { MB::Sound.live = false }

  it 'is off by default' do
    expect(MB::Sound.live?).to eq(false)
  end

  it 'raises the given error outside live mode' do
    expect { MB::Sound.live_error(ArgumentError.new('nope')) }.to raise_error(ArgumentError, 'nope')
  end

  it 'warns and returns nil in live mode' do
    MB::Sound.live = true
    expect(MB::Sound.live?).to eq(true)
    result = nil
    expect { result = MB::Sound.live_error(ArgumentError.new('nope')) }.to output(/ArgumentError: nope.*live mode: ignored/).to_stderr
    expect(result).to be_nil
  end
end
