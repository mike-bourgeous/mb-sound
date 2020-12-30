RSpec.describe MB::Sound::Filter::Butterworth do
  context 'lowpass' do
    for order in 1..10 do
      it "can construct a filter of order #{order} without crashing" do
        f = nil
        expect { f = MB::Sound::Filter::Butterworth.new(:lowpass, order, 48000, 12000) }.not_to raise_error
        expect { f.process([0]) }.not_to raise_error
        expect { f.response(0) }.not_to raise_error
        expect { f.z_response(1) }.not_to raise_error
      end
    end

    it 'constructs a single-pole/single-zero filter for order 1' do
      f_but = MB::Sound::Filter::Butterworth.new(:lowpass, 1, 48000, 2400)
      f_lpfo = MB::Sound::Filter::FirstOrder.new(:lowpass, 48000, 2400)

      expect(f_but.polezero).to eq(f_lpfo.polezero)
      expect(f_but.response(0.1)).to eq(f_lpfo.response(0.1))
      expect(f_but.response(0.4)).to eq(f_lpfo.response(0.4))
    end

    it 'returns the correct poles and zeros for 2400/48000/5' do
      poles = [
        0.86816+0.26827i,
        0.86816-0.26827i,
        0.76085+0.14531i,
        0.76085-0.14531i,
        0.72654,
      ]
      zeros = [
        -1,
        -1,
        -1,
        -1,
        -1
      ]

      fpz = MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 2400).polezero

      expect(fpz[:poles].map { |v| Sound.sigfigs(v, 5) }).to eq(poles)
      expect(fpz[:zeros].map { |v| Sound.sigfigs(v, 5) }).to eq(zeros)
    end

    pending
  end

  context 'highpass' do
    for order in 1..10 do
      it "can construct a filter of order #{order} without crashing" do
        f = nil
        expect { f = MB::Sound::Filter::Butterworth.new(:highpass, order, 48000, 12000) }.not_to raise_error
        expect { f.process([0]) }.not_to raise_error
      end
    end

    pending
  end
end
