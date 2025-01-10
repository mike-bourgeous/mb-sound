require 'stringio'

RSpec.describe(MB::Sound::IOLogger, :aggregate_failures) do
  let(:filename) { 'sounds/piano0.flac' }
  let(:file) { MB::Sound.file_input(filename) }
  let(:nulloutput) { MB::Sound::NullOutput.new(channels: 2) }

  it 'can attach to a file input' do
    file.singleton_class.prepend(MB::Sound::IOLogger)
    output_str = ''.dup
    file.iolog_output = StringIO.new(output_str, 'w')

    data = file.read(23459)
    expect(data.length).to eq(2)
    expect(data[0].length).to eq(23459)

    file.close

    expect(output_str).to match(/FFMPEG.*read 23459.*Got.*2.*23459/m)
  end

  it 'can attach to a null output' do
    nulloutput.singleton_class.prepend(MB::Sound::IOLogger)
    output_str = ''.dup
    nulloutput.iolog_output = StringIO.new(output_str, 'w')

    nulloutput.write([Numo::SFloat.zeros(123), Numo::SFloat.ones(123)])

    expect(output_str).to match(/NullOutput.*write 2.*123, 123/)
  end

  it 'attaches to most inputs and outputs when IOLOG env var is 1' do
    output = `IOLOG=1 bin/plot.rb sounds/piano0.flac 2>&1`
    output = MB::U.remove_ansi(output)
    expect($?).to be_success
    expect(output).to match(/FFMPEGInput.*read 87493 frames.*succeeded/)
  end
end
