RSpec.describe MB::Sound::WindowWriter do
  describe '#initialize' do
    it 'can wrap a NullOutput' do
      writer = MB::Sound::WindowWriter.new(
        MB::Sound::NullOutput.new(channels: 3, buffer_size: 576),
        MB::Sound::Window::DoubleHann.new(1234)
      )
      expect(writer.buffer_size).to eq(1234)
      expect(writer.channels).to eq(3)
    end
  end

  describe '#write' do
    it 'eventually writes to the downstream output' do
      nulloutput = MB::Sound::NullOutput.new(channels: 1, buffer_size: 576, strict_buffer_size: true)
      writer = MB::Sound::WindowWriter.new(
        nulloutput,
        MB::Sound::Window::DoubleHann.new(1234)
      )
      expect(nulloutput).to receive(:write).with([Numo::SFloat.zeros(576)]).and_call_original
      writer.write([Numo::SFloat.zeros(1234)])
      writer.write([Numo::SFloat.zeros(1234)])
      writer.write([Numo::SFloat.zeros(1234)])
      writer.write([Numo::SFloat.zeros(1234)])
    end
  end

  # TODO: This needs way more tests (it's currently tested in situ in another project)

  pending 'pad factor'
  pending 'different windows with/without post window'
end
