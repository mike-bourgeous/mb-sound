MB::Sound::Window.windows.each do |wclass|
  length = 256
  bin = 8

  RSpec.describe wclass do
    it 'should have an FFT value of 1.0 for a bin-centered sine wave' do
      window = wclass.new(length)
      sine = length.times.map { |i| Math.sin(bin * 2.0 * Math::PI * i / length) }

      wsine = Numo::SFloat.cast(sine) * window.pre_window
      fft = MB::Sound.real_fft(wsine)

      expect(fft.abs.max).to be_within(0.00001).of(1)
    end

    it 'should sum to a constant when overlapped' do
      window = wclass.new(length)
      n = 4 * window.length / window.hop
      ovl = window.gen_overlap(n)
      from = ovl.size * 7/16
      to = ovl.size * 9/16
      ovl = ovl[from..to]
      expect(ovl.min).to be_within(0.00001).of(ovl.max)
      expect(ovl.min).to be_within(0.00001).of(1.0 / window.overlap_gain)
      expect(ovl.max).to be_within(0.00001).of(1.0 / window.overlap_gain)
    end
  end
end
