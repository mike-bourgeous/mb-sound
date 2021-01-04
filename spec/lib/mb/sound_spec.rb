require 'fileutils'

RSpec.describe MB::Sound do
  context 'IOMethods' do
    describe '.read' do
      it 'can read a sound file' do
        a = MB::Sound.read('sounds/sine/sine_100_1s_mono.flac')
        expect(a.length).to eq(1)
        expect(a[0].length).to eq(48000)
        expect(a[0].max).to be_between(0.4, 1.0)
      end

      it 'can read part of a sound file' do
        a = MB::Sound.read('sounds/sine/sine_100_1s_mono.flac', max_frames: 500)
        expect(a.length).to eq(1)
        expect(a[0].length).to eq(500)
      end
    end

    describe '.write' do
      before(:each) do
        FileUtils.mkdir_p('tmp')
        File.unlink('tmp/sound_write_test.flac') rescue nil
        File.unlink('tmp/sound_write_exists.flac') rescue nil
      end

      context 'when writing to a file that does not yet exist' do
        let(:name) { 'tmp/sound_write_test.flac' }
        let(:data) { Numo::SFloat[0, 0.5, -0.5, 0] }

        it 'can write an array of NArrays to a sound file' do
          MB::Sound.write(name, [data], rate: 48000)
          info = MB::Sound::FFMPEGInput.parse_info(name)
          expect(info[:streams][0][:duration_ts]).to eq(4)
        end

        it 'can write a raw NArray to a sound file' do
          MB::Sound.write(name, data, rate: 48000)
          info = MB::Sound::FFMPEGInput.parse_info(name)
          expect(info[:streams][0][:duration_ts]).to eq(4)
        end

        it 'can write a Tone to a sound file' do
          MB::Sound.write(name, 100.hz.for(1), rate: 48000)
          info = MB::Sound::FFMPEGInput.parse_info(name)
          expect(info[:streams][0][:duration_ts]).to eq(48000)
          expect(info[:streams][0][:channels]).to eq(1)
        end

        it 'can write multiple tones to a sound file' do
          MB::Sound.write(name, [100.hz.for(1), 200.hz.for(1)], rate: 48000)
          info = MB::Sound::FFMPEGInput.parse_info(name)
          expect(info[:streams][0][:duration_ts]).to eq(48000)
          expect(info[:streams][0][:channels]).to eq(2)
        end
      end

      context 'when overwrite is false (by default)' do
        it 'raises an error if the sound already exists' do
          name = 'tmp/sound_write_exists.flac'
          FileUtils.touch(name)
          expect {
            MB::Sound.write(name, [Numo::SFloat[0, 0.1, -0.2, 0.3]], rate: 48000)
          }.to raise_error(MB::Sound::FileExistsError)
        end
      end

      context 'when overwrite is true' do
        it 'overwrites an existing file' do
          name = 'tmp/sound_write_exists.flac'

          FileUtils.touch(name)
          expect(File.size(name)).to eq(0)

          MB::Sound.write(name, [Numo::SFloat[0, 0.1, -0.2, 0.3]], rate: 48000, overwrite: true)
          expect(File.size(name)).to be > 0
        end
      end
    end
  end

  context 'FFTMethods' do
    3.times do |n|
      ndim = n + 1

      context "with a #{ndim}D array" do
        let(:dc_input_small) {
          Numo::DFloat.ones(*([10] * ndim))
        }

        let(:dc_input_large) {
          Numo::DFloat.ones(*([32] * ndim))
        }

        let(:sine_input_small) {
          tone = 12000.hz.at(1).generate(24)
          n.times do
            tone = Numo::SFloat.cast([tone] * 24)
          end
          tone
        }

        let(:sine_input_large) {
          tone = 4000.hz.at(1).generate(48)
          n.times do
            tone = Numo::SFloat.cast([tone] * 48)
          end
          tone
        }

        describe '.fft' do
          it 'returns a DC value of 1.0 for an array filled with ones' do
            expect(MB::Sound.fft(dc_input_small)[*([0] * ndim)].real.round(5)).to eq(1)
            expect(MB::Sound.fft(dc_input_small)[*([1] * ndim)].real.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_small)[*([0] * ndim)].imag.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_small)[*([1] * ndim)].imag.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_small).sum.real.round(5)).to eq(1)
            expect(MB::Sound.fft(dc_input_small).sum.imag.round(5)).to eq(0)

            expect(MB::Sound.fft(dc_input_large)[*([0] * ndim)].real.round(5)).to eq(1)
            expect(MB::Sound.fft(dc_input_large)[*([1] * ndim)].real.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_large)[*([0] * ndim)].imag.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_large)[*([1] * ndim)].imag.round(5)).to eq(0)
            expect(MB::Sound.fft(dc_input_large).sum.real.round(5)).to eq(1)
            expect(MB::Sound.fft(dc_input_large).sum.imag.round(5)).to eq(0)
          end

          it 'returns + and - bin values of +/-0.5i for a bin-centered sinusoid' do
            small_idx = [0] * n + [6]
            small_fft = MB::Sound.fft(sine_input_small)
            expect(small_fft.abs.sum.round(6)).to eq(1)
            expect(MB::Sound::M.round(small_fft[*small_idx], 6)).to eq(0-0.5i)
            expect(MB::Sound::M.round(small_fft[*small_idx.map(&:-@)], 6)).to eq(0+0.5i)

            large_idx = [0] * n + [4]
            large_fft = MB::Sound.fft(sine_input_large)
            expect(large_fft.abs.sum.round(6)).to eq(1)
            expect(MB::Sound::M.round(large_fft[*large_idx], 6)).to eq(0-0.5i)
            expect(MB::Sound::M.round(large_fft[*large_idx.map(&:-@)], 6)).to eq(0+0.5i)
          end

          pending 'returns 0 phase for a cosine'

          pending 'returns PI/4 phase for a sine'
        end

        describe '.ifft' do
          pending 'returns the original signal when passed the output of #fft'
          pending 'returns an array of all ones for a 1.0 DC value'
        end

        describe '.real_fft' do
          pending
        end

        describe '.real_ifft' do
          pending
        end
      end
    end
  end

  describe '.filter' do
    it 'reduces the amplitude of high frequencies more than low frequencies' do
      low = MB::Sound.filter(123.hz.at(0.1), frequency: 1000, quality: 0.5)
      low_gain = low[0].abs.max / 0.1

      high = MB::Sound.filter(15000.hz.at(0.1), frequency: 1000, quality: 0.5)
      high_gain = high[0].abs.max / 0.1

      expect(low_gain).to be > high_gain
      expect(low_gain).to be > -1.db
      expect(high_gain).to be < -30.db
    end
  end
end
