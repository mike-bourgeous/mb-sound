RSpec.describe(MB::Sound::IOLogger) do
  let(:filename) { 'sounds/piano0.flac' }
  let(:file) { MB::Sound.file_input(filename) }

  it 'can attach to a file input' do
    file.singleton_class.prepend(MB::Sound::IOLogger)
  end

  it 'can attach to a null output' do
  end

  it 'attaches to most inputs and outputs when IOLOG env var is 1' do
    output = `IOLOG=1 bin/plot.rb sounds/piano0.flac`
    output = MB::U.remove_ansi(output)
    expect(output).to match(/FFMPEGInput.*read 87493 frames.*succeeded/)
  end
end
