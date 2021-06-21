# FFTMethods are tested via Sound
RSpec.describe(MB::Sound::FFTMethods) do
  [:fft, :real_fft].each do |m|
    describe "##{m}" do
      it 'can process a Tone object' do
        fft = MB::Sound.send(m, 4000.hz.at(1).for(1))
        expect(fft.abs.max_index).to eq(4000)
        expect(fft[4000].abs.round(3)).to eq(1)
      end

      it 'can process an Array of Tone objects' do
        fft = MB::Sound.send(m, [4000.hz.at(1).for(1), 8000.hz.at(1).for(1)])
        expect(fft).to be_a(Array)
        expect(fft[0].abs.max_index).to eq(4000)
        expect(fft[1].abs.max_index).to eq(8000)
        expect(fft[0][4000].abs.round(3)).to eq(1)
        expect(fft[0][8000].abs.round(3)).to eq(0)
        expect(fft[1][4000].abs.round(3)).to eq(0)
        expect(fft[1][8000].abs.round(3)).to eq(1)
      end
    end
  end

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
        tone = Numo::DFloat.cast(12000.hz.at(1).generate(24))
        n.times do
          tone = Numo::DFloat.cast([tone] * 24)
        end
        tone
      }

      let(:sine_input_large) {
        tone = Numo::DFloat.cast(4000.hz.at(1).generate(48))
        n.times do
          tone = Numo::DFloat.cast([tone] * 48)
        end
        tone
      }

      let(:small_idx) {
        [0] * n + [6]
      }

      let(:large_idx) {
        [0] * n + [4]
      }

      let(:cosine_input) {
        tone = Numo::DFloat.cast(12000.hz.with_phase(90.degrees).at(1).generate(24))
        n.times do
          tone = Numo::DFloat.cast([tone] * 24)
        end
        tone
      }

      let(:ramp_input) {
        tone = Numo::DFloat.cast(4000.hz.ramp.at(1).generate(48))
        n.times do
          tone = Numo::DFloat.cast([tone] * 48)
        end
        tone
      }

      let(:all_inputs) {
        {
          dc_input_small: dc_input_small,
          dc_input_large: dc_input_large,
          sine_input_small: sine_input_small,
          sine_input_large: sine_input_large,
          cosine_input: cosine_input,
          ramp_input: ramp_input,
        }
      }

      describe '#fft' do
        it 'returns a DC value of 2.0 for an array filled with ones' do
          expect(MB::Sound.fft(dc_input_small)[*([0] * ndim)].real.round(4)).to eq(2)
          expect(MB::Sound.fft(dc_input_small)[*([1] * ndim)].real.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_small)[*([0] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_small)[*([1] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_small).sum.real.round(5)).to eq(2)
          expect(MB::Sound.fft(dc_input_small).sum.imag.round(5)).to eq(0)

          expect(MB::Sound.fft(dc_input_large)[*([0] * ndim)].real.round(4)).to eq(2)
          expect(MB::Sound.fft(dc_input_large)[*([1] * ndim)].real.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_large)[*([0] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_large)[*([1] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.fft(dc_input_large).sum.real.round(5)).to eq(2)
          expect(MB::Sound.fft(dc_input_large).sum.imag.round(5)).to eq(0)
        end

        it 'returns + and - bin values of +/-1i for a bin-centered sinusoid' do
          small_fft = MB::Sound.fft(sine_input_small)
          expect(small_fft.abs.sum.round(6)).to eq(2)
          expect(MB::M.round(small_fft[*small_idx], 6)).to eq(0-1i)
          expect(MB::M.round(small_fft[*small_idx.map(&:-@)], 6)).to eq(0+1i)

          large_fft = MB::Sound.fft(sine_input_large)
          expect(large_fft.abs.sum.round(6)).to eq(2)
          expect(MB::M.round(large_fft[*large_idx], 6)).to eq(0-1i)
          expect(MB::M.round(large_fft[*large_idx.map(&:-@)], 6)).to eq(0+1i)
        end

        it 'returns 0 phase for a cosine' do
          fft = MB::Sound.fft(cosine_input)
          expect(fft[*small_idx].real.round(6)).to eq(1)
          expect(fft[*small_idx].imag.round(6)).to eq(0)
          expect(fft[*small_idx.map(&:-@)].abs.round(6)).to eq(1)
          expect(fft[*small_idx.map(&:-@)].arg.round(6)).to eq(0)
        end

        it 'returns PI/4 phase for a sine' do
          fft = MB::Sound.fft(sine_input_small)
          expect(fft[*small_idx].abs.round(6)).to eq(1)
          expect(fft[*small_idx].arg.round(6)).to eq(-(Math::PI / 2).round(6))
          expect(fft[*small_idx.map(&:-@)].abs.round(6)).to eq(1)
          expect(fft[*small_idx.map(&:-@)].arg.round(6)).to eq((Math::PI / 2).round(6))
        end

        it 'can process an Array of Float' do
          small_fft = MB::Sound.fft(sine_input_small.to_a)
          expect(small_fft.abs.sum.round(6)).to eq(2)
          expect(MB::M.round(small_fft[*small_idx], 6)).to eq(0-1i)
        end

        it 'can process an Array of Complex' do
          small_fft = MB::Sound.fft(Numo::SComplex.cast(sine_input_small).to_a)
          expect(Numo::SComplex.cast(small_fft).abs.sum.round(6)).to eq(2)
          expect(MB::M.round(small_fft[*small_idx], 6)).to eq(0-1i)
        end

        it 'can process an Array of NArrays' do
          ffts = MB::Sound.fft([sine_input_small, sine_input_large])
          expect(ffts[0][*small_idx].abs.round).to eq(1)
          expect(ffts[1][*large_idx].abs.round).to eq(1)
        end
      end

      describe '#ifft' do
        it "returns the original signal when passed the output of #fft" do
          all_inputs.each do |name, input|
            fft = MB::Sound.fft(input)
            inv_fft = MB::Sound.ifft(fft).real

            # Including the name so the diff for failed comparisons will show the name
            expect([name, MB::M.round(inv_fft, 6)]).to eq([name, MB::M.round(input, 6)])
          end
        end

        it 'returns an array of all ones for a 2.0 DC value' do
          dc_fft = Numo::DFloat.zeros([5] * ndim)
          dc_fft[0] = 2
          result = MB::Sound.ifft(dc_fft)
          expect(result.sum.abs.round(6)).to eq(5 ** ndim)
          expect(result.abs.min.round(6)).to eq(1)
          expect(result.abs.max.round(6)).to eq(1)
        end

        it 'can process an Array of Complex' do
          fft_arr = MB::Sound.fft(sine_input_small).to_a

          first = fft_arr
          while first.is_a?(Array)
            first = first[0]
          end
          expect(first).to be_a(Complex)

          inv_fft = MB::Sound.ifft(fft_arr)
          expect(MB::M.round(inv_fft, 6)).to eq(MB::M.round(sine_input_small, 6))
        end

        it 'can process an Array of NArrays' do
          ffts = MB::Sound.fft(all_inputs.values)
          inv_ffts = MB::Sound.ifft(ffts)
          expect(MB::M.round(inv_ffts, 6)).to eq(MB::M.round(all_inputs.values, 6))
        end
      end

      describe '#real_fft' do
        it 'returns only the positive frequencies' do
          expect(MB::Sound.real_fft(ramp_input).shape).to eq([48] * (ndim - 1) + [25])
        end

        it 'returns a DC value of 2.0 for an array filled with ones' do
          expect(MB::Sound.real_fft(dc_input_small)[*([0] * ndim)].real.round(4)).to eq(2)
          expect(MB::Sound.real_fft(dc_input_small)[*([1] * ndim)].real.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_small)[*([0] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_small)[*([1] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_small).sum.real.round(5)).to eq(2)
          expect(MB::Sound.real_fft(dc_input_small).sum.imag.round(5)).to eq(0)

          expect(MB::Sound.real_fft(dc_input_large)[*([0] * ndim)].real.round(4)).to eq(2)
          expect(MB::Sound.real_fft(dc_input_large)[*([1] * ndim)].real.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_large)[*([0] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_large)[*([1] * ndim)].imag.round(4)).to eq(0)
          expect(MB::Sound.real_fft(dc_input_large).sum.real.round(5)).to eq(2)
          expect(MB::Sound.real_fft(dc_input_large).sum.imag.round(5)).to eq(0)
        end

        it 'returns a bin value of -1i for a bin-centered sinusoid' do
          small_fft = MB::Sound.real_fft(sine_input_small)
          expect(MB::M.round(small_fft[*small_idx], 6)).to eq(0-1i)
          expect(small_fft.abs.sum.round(6)).to eq(1)

          large_fft = MB::Sound.real_fft(sine_input_large)
          expect(MB::M.round(large_fft[*large_idx], 6)).to eq(0-1i)
          expect(large_fft.abs.sum.round(6)).to eq(1)
        end

        it 'returns 0 phase for a cosine' do
          fft = MB::Sound.real_fft(cosine_input)
          expect(fft[*small_idx].real.round(6)).to eq(1)
          expect(fft[*small_idx].imag.round(6)).to eq(0)
        end

        it 'returns PI/4 phase for a sine' do
          fft = MB::Sound.real_fft(sine_input_small)
          expect(fft[*small_idx].abs.round(6)).to eq(1)
          expect(fft[*small_idx].arg.round(6)).to eq(-(Math::PI / 2).round(6))
        end

        it 'can process an Array of Float' do
          small_fft = MB::Sound.real_fft(sine_input_small.to_a)
          expect(small_fft.abs.sum.round(6)).to eq(1)
          expect(MB::M.round(small_fft[*small_idx], 6)).to eq(0-1i)
        end

        it 'can process an Array of NArrays' do
          ffts = MB::Sound.real_fft([sine_input_small, sine_input_large])
          expect(ffts[0][*small_idx].abs.round).to eq(1)
          expect(ffts[1][*large_idx].abs.round).to eq(1)
        end
      end

      describe '#real_ifft' do
        it "returns the original signal when passed the output of #real_fft" do
          all_inputs.each do |name, input|
            fft = MB::Sound.real_fft(input)
            inv_fft = MB::Sound.real_ifft(fft)

            # Including the name so the diff for failed comparisons will show the name
            expect([name, MB::M.round(inv_fft, 6)]).to eq([name, MB::M.round(input, 6)])
          end
        end

        it 'returns an array of all ones for a 2.0 DC value' do
          dc_fft = Numo::DFloat.zeros([5] * ndim)
          dc_fft[0] = 2
          result = MB::Sound.real_ifft(dc_fft)
          expect(result.sum.abs.round(6)).to eq(result.length)
          expect(result.abs.min.round(6)).to eq(1)
          expect(result.abs.max.round(6)).to eq(1)
        end

        it 'can process an Array of Complex' do
          fft_arr = MB::Sound.real_fft(sine_input_small).to_a

          first = fft_arr
          while first.is_a?(Array)
            first = first[0]
          end
          expect(first).to be_a(Complex)

          inv_fft = MB::Sound.real_ifft(fft_arr)
          expect(MB::M.round(inv_fft, 6)).to eq(MB::M.round(sine_input_small, 6))
        end

        it 'can process an Array of NArrays' do
          ffts = MB::Sound.real_fft(all_inputs.values)
          inv_ffts = MB::Sound.real_ifft(ffts)
          expect(MB::M.round(inv_ffts, 6)).to eq(MB::M.round(all_inputs.values, 6))
        end

        context 'with odd_length: true' do
          if ndim == 1
            it "returns the original data from an odd-length dataset with #{ndim} dimensions" do
              all_inputs.each do |name, input|
                odd = input[0..-2]
                fft = MB::Sound.real_fft(odd)
                inv_fft = MB::Sound.real_ifft(fft, odd_length: true)

                expect([name, MB::M.round(inv_fft, 6)]).to eq([name, MB::M.round(odd, 6)])
              end
            end

            it 'can process a numeric Array' do
              odd = sine_input_small[0..-2].to_a
              fft_arr = MB::Sound.real_fft(odd)
              inv_fft = MB::Sound.real_ifft(fft_arr, odd_length: true)
              expect(MB::M.round(inv_fft, 6)).to eq(MB::M.round(odd, 6))
            end
          else
            pending "#{ndim} dimensions"
          end
        end
      end
    end
  end

  describe '#analytic_signal' do
    [0, 1].each do |l|
      context "with #{l == 0 ? 'even' : 'odd'} length" do
        it 'preserves a simple input signal as the real value of the output signal' do
          s = Numo::SFloat[1, 0, -1, 0, 1, 0, -1, 0, 1]
          s = s[0..-2] if l == 0
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(s)
        end

        it 'preserves a sine wave as the real value of the output signal' do
          s = (100 + l).times.map { |v|
            Math.sin(v * Math::PI / 50)
          }
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(MB::M.round(s, 4))
        end

        it 'preserves a cosine wave as the real value of the output signal' do
          s = (100 + l).times.map { |v|
            Math.cos(v * Math::PI / 50)
          }
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(MB::M.round(s, 4))
        end

        it 'preserves an off-integer-multiple cosine wave as real output' do
          s = (100 + l).times.map { |v|
            Math.cos(v * Math::PI / 37.13487)
          }
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(MB::M.round(s, 4))
        end

        it 'preserves the sum of two frequencies as real output' do
          s = (100 + l).times.map { |v|
            Math.sin(v * Math::PI / 59.3) + Math.cos(v * Math::PI / 11.97)
          }
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(MB::M.round(s, 4))
        end

        it 'preserves a linear ramp as real output' do
          s = Numo::DFloat.linspace(-1, 1, 10 + l)
          a = MB::Sound.analytic_signal(s)
          expect(MB::M.round(a.real, 4)).to eq(MB::M.round(s, 4))
        end
      end
    end

    it 'can process a Tone' do
      signal = MB::Sound.analytic_signal(300.hz.at(1))
      expect(signal.real.max.round(6)).to eq(1)
      expect(signal.real.min.round(6)).to eq(-1)
      expect(signal.imag.max.round(6)).to eq(1)
      expect(signal.imag.min.round(6)).to eq(-1)
    end

    it 'can process an Array of Tones' do
      signal = MB::Sound.analytic_signal([300.hz.at(1), 400.hz.at(0.1)])
      expect(signal.map { |c| c.real.max.round(6) }).to eq([1, 0.1])
      expect(signal.map { |c| c.real.min.round(6) }).to eq([-1, -0.1])
      expect(signal.map { |c| c.imag.max.round(6) }).to eq([1, 0.1])
      expect(signal.map { |c| c.imag.min.round(6) }).to eq([-1, -0.1])
    end
  end

  pending '#trunc_fft'

  describe '.unwrap_phase' do
    def linear_phase(start, stop, n)
      phase = Numo::DFloat.linspace(start, stop, n).inplace!.map { |v| MB::M.sigfigs(v, 6) }
      cplx = Numo::DComplex.zeros(n).inplace!.map_with_index { |_, idx| Complex.polar(1.0, phase[idx]) }
      return phase.not_inplace!, cplx.not_inplace!
    end

    def sine_phase(amp, n)
      phase = Numo::DFloat.linspace(0.0, Math::PI * 6.0, n).inplace!.map { |v|
        MB::M.sigfigs(Math.sin(v) * amp, 6)
      }
      cplx = Numo::DComplex.zeros(n).inplace!.map_with_index { |_, idx| Complex.polar(1.0, phase[idx]) }
      return phase.not_inplace!, cplx.not_inplace!
    end

    def unwrapped_sigfigs(cplx)
      MB::Sound.unwrap_phase(cplx).inplace!.map{ |v| MB::M.sigfigs(v, 6) }.not_inplace!
    end

    it 'returns phase unmodified when delta is less than pi' do
      # Generate linear phase from -pi to pi using Complex.polar
      phase, complex = linear_phase(-Math::PI, Math::PI, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct a single discontinuity upward' do
      # Generate linear phase from -pi to 2pi using Complex.polar
      phase, complex = linear_phase(-Math::PI, 2.0 * Math::PI, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct a single discontinuity downward' do
      # Generate linear phase from pi to -2pi using Complex.polar
      phase, complex = linear_phase(Math::PI, -2.0 * Math::PI, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct repeating discontinuities upward' do
      # Generate linear phase from -pi to 5pi
      phase, complex = linear_phase(-Math::PI, 7.0 * Math::PI, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct repeating discontinuities downward' do
      # Generate linear phase from pi to -5pi
      phase, complex = linear_phase(Math::PI, -7.0 * Math::PI, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'passes through non-wrapping sinusoidal phase' do
      # Generate sinusoidal phase with magnitude less than pi to verify sinusoidal generation
      phase, complex = sine_phase(2.0, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct alternating discontinuities' do
      # Generate sinusoidal phase using Complex.polar with magnitude between pi and 2pi
      phase, complex = sine_phase(4.0, 100)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end

    it 'can correct repeating and alternating discontinuities' do
      # Generate sinusoidal phase using Complex.polar with magnitude greater than 3pi
      phase, complex = sine_phase(20.0, 500)
      expect(MB::M.sigfigs(complex.angle, 6).to_a).not_to eq(phase.to_a)
      expect(unwrapped_sigfigs(complex).to_a).to eq(phase.to_a) # to_a because narray truncates to_s
    end
  end
end
