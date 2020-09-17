require 'fileutils'

RSpec.describe MB::Sound::FFMPEGOutput do
  let(:test_data) {
    [
      Numo::SFloat[0, 0.5, -0.5, 0],
      Numo::SFloat[0, -0.75, 0.25, 0],
      Numo::SFloat[0, -0.25, 0.75, 0],
    ]
  }

  before(:all) do
    FileUtils.mkdir_p('./tmp')
    File.unlink('./tmp/test_out.flac') rescue nil
    File.unlink('./tmp/test_out.wav') rescue nil
  end

  ['flac', 'wav'].each do |format|
    context "when writing .#{format}" do
      it 'can write a file that can be read by FFMPEGInput' do
        name = "tmp/test_out.#{format}"
        output = MB::Sound::FFMPEGOutput.new(name, rate: 44100, channels: 3)
        expect(output.filename).to include(name)
        output.write(test_data)
        expect(output.close.success?).to eq(true)

        expect(File.readable?(name)).to eq(true)
        expect(File.size(name)).to be > 0

        input = MB::Sound::FFMPEGInput.new(name)
        expect(input.rate).to eq(44100)
        expect(input.channels).to eq(3)
        expect(input.frames).to eq(4)

        data = input.read(input.frames).map { |c|
          c.map { |v| v.round(3) }
        }

        expect(input.close.success?).to eq(true)

        expect(data).to eq(test_data)
      end
    end
  end
end
