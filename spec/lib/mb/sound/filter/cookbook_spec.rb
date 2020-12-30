RSpec.describe MB::Sound::Filter::Cookbook do
  context 'lowpass' do
    it 'produces the right coefficients for 25Hz/48kHz/Q0.707' do
      coeff_25 = [
        0.0000026711181320911584,
        0.000005342236264182317,
        0.0000026711181320911584,
        -1.9953719609930045,
        0.9953826454655329
      ]

      result = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 25, quality: 0.7071)

      ratios = result.coefficients.zip(coeff_25).map { |a, b| (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end

    it 'produces the right coefficients for 2kHz/48kHz/Q0.707' do
      coeff_2k = [
        0.014401418980573148,
        0.028802837961146296,
        0.014401418980573148,
        -1.6329907391512004,
        0.690596415073493
      ]

      result = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 2000, quality: 0.7071)

      ratios = result.coefficients.zip(coeff_2k).map { |a, b| (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end

    it 'produces the right coefficients for 3620/27015/Q1' do
      coeff = [
        0.12162918590236202,
        0.24325837180472404,
        0.12162918590236202,
        -0.9701795381442064,
        0.4566962817536547
      ]

      result = MB::Sound::Filter::Cookbook.new(:lowpass, 27015, 3620, quality: 1)

      ratios = result.coefficients.zip(coeff).map { |a, b| (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end

    it 'produces the right poles and zeros for 2400/48000/Q0.707' do
      poles = [
        0.781+0.179i,
        0.781-0.179i
      ]
      zeros = [
        -1,
        -1
      ]

      fpz = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 2400, quality: 0.5 ** 0.5).polezero

      expect(fpz[:poles].map { |v| Sound.sigfigs(v, 3) }).to eq(poles)
      expect(fpz[:zeros].map { |v| Sound.sigfigs(v, 3) }).to eq(zeros)
    end
  end

  context 'highpass' do
    it 'produces the expected transfer function for 5k/48k/Q.707' do
      biquad = MB::Sound::Filter::Biquad.new(
        0.6268434626266253,
        -1.2536869252532505,
        0.6268434626266253,
        -1.10922559150289,
        0.3981482590036111
      )

      cookbook = MB::Sound::Filter::Cookbook.new(:highpass, 48000, 5000, quality: 0.7071)

      freqs = Numo::DComplex.logspace(Math.log2(20), Math.log2(20000), 10, 2)

      cb_resp = freqs.map { |f|
        cookbook.response(f.abs)
      }

      bq_resp = freqs.map { |f|
        biquad.response(f.abs)
      }

      magratio = cb_resp.abs / bq_resp.abs
      phaseratio = cb_resp.arg / bq_resp.arg

      expect((magratio - 1.0).abs.max).to be <= 0.00001
      expect((phaseratio - 1.0).abs.max).to be <= 0.00001
    end

    it 'produces the right coefficients for 5k/48k/Q.707' do
      coeff = [
        0.6268434626266253,
        -1.2536869252532505,
        0.6268434626266253,
        -1.10922559150289,
        0.3981482590036111
      ]

      result = MB::Sound::Filter::Cookbook.new(:highpass, 48000, 5000, quality: 0.7071)

      ratios = result.coefficients.zip(coeff).map { |a, b| (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end
  end

  context 'bandpass' do
    it 'produces the right coefficients for 5k/48k/Q50' do
      coeff = [
        0.006050779478467919,
        0,
        -0.006050779478467919,
        -1.577105868361254,
        0.9878984410430642
      ]

      result = MB::Sound::Filter::Cookbook.new(:bandpass, 48000, 5000, quality: 50)

      ratios = result.coefficients.zip(coeff).map { |a, b| a == b ? 1 : (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end
  end

  context 'notch' do
    it 'produces the right coefficients for 5k/48k/Q2' do
      coeff = [
        0.867912141171591,
        -1.3771219925555995,
        0.867912141171591,
        -1.3771219925555995,
        0.735824282343182
      ]

      result = MB::Sound::Filter::Cookbook.new(:notch, 48000, 5000, quality: 2)

      ratios = result.coefficients.zip(coeff).map { |a, b| a == b ? 1 : (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end
  end

  context 'peak' do
    # Note: using cookbook definition of Q, so other generators may need to
    # enter Q * sqrt(gain), or 7.06268772311 in this case.
    it 'produces the right coefficients for 5k/48k/Q5/G6' do
      coeff = [
        1.0411206516017641,
        -1.5211496795535877,
        0.8762465570560869,
        -1.5211496795535877,
        0.9173672086578509
      ]

      result = MB::Sound::Filter::Cookbook.new(:peak, 48000, 5000, db_gain: 6, quality: 5)

      ratios = result.coefficients.zip(coeff).map { |a, b| a == b ? 1 : (a / b).round(6) }

      expect(ratios).to eq([1] * 5)
    end

    it 'produces the expected transfer function for 5k/48k/Q5/G6' do
      biquad = MB::Sound::Filter::Biquad.new(
        1.0411206516017641,
        -1.5211496795535877,
        0.8762465570560869,
        -1.5211496795535877,
        0.9173672086578509
      )

      cookbook = MB::Sound::Filter::Cookbook.new(:peak, 48000, 5000, db_gain: 6, quality: 5)

      freqs = Numo::DComplex.logspace(Math.log2(20), Math.log2(20000), 10, 2)

      cb_resp = freqs.map { |f|
        cookbook.response(f.abs)
      }

      bq_resp = freqs.map { |f|
        biquad.response(f.abs)
      }

      magratio = cb_resp.abs / bq_resp.abs
      phaseratio = cb_resp.arg / bq_resp.arg

      expect((magratio - 1.0).abs.max).to be <= 0.00001
      expect((phaseratio - 1.0).abs.max).to be <= 0.00001
    end
  end

  context 'lowshelf' do
    # Note: the cookbook uses shelf midpoint rather than approx 3dB point, so I
    # used 6.02dB and 1038.50712Hz in an online calculator to match 1234Hz here
    # Approximate ratio is 1.18788735818 lower for this particular low shelf.
    #
    # Used bin/find_biquad.rb plus a bit of manual tweaking to find the value
    it 'produces the expected transfer function for 1234/43210/Q.7/G6' do
      biquad = MB::Sound::Filter::Biquad.new(
        1.0449630797853982,
        -1.7768488823989634,
        0.7730275257848368,
        -1.78713360277755,
        0.8077058851916483
      )

      cookbook = MB::Sound::Filter::Cookbook.new(:lowshelf, 43210, 1234, db_gain: 6.02, quality: 0.7071)

      freqs = Numo::DComplex.logspace(Math.log2(20), Math.log2(20000), 10, 2)

      cb_resp = freqs.map { |f|
        cookbook.response(f.abs)
      }

      bq_resp = freqs.map { |f|
        biquad.response(f.abs)
      }

      magratio = cb_resp.abs / bq_resp.abs
      phaseratio = cb_resp.arg / bq_resp.arg

      expect((magratio - 1.0).abs.max).to be <= 0.00001
      expect((phaseratio - 1.0).abs.max).to be <= 0.00001
    end

    it 'produces the right coefficients for 1234/43210/G6' do
      coeff = [
        1.0449630797853982,
        -1.7768488823989634,
        0.7730275257848368,
        -1.78713360277755,
        0.8077058851916483
      ]

      result = MB::Sound::Filter::Cookbook.new(:lowshelf, 43210, 1234, db_gain: 6.02, quality: 0.7071)

      ratios = result.coefficients.zip(coeff).map { |a, b| a == b ? 1 : (a / b).round(5) } # using weaker rounding due to frequency offset

      expect(ratios).to eq([1] * 5)
    end

    [-6.02, 0, 6.02].each do |gain|
      context "with #{gain}dB gain" do
        it 'has the right frequency response when processing noise' do
          filter = MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 1234, db_gain: gain, quality: 0.7071)

          # Each fft bin should be 1hz
          noise = Numo::SFloat.new(48000).rand(-1, 1)
          before = Sound.pos_dft(noise)
          below_before = before[10..200].abs.sum
          above_before = before[10000..20000].abs.sum

          filter.reset(noise[0])
          result = filter.process(noise)
          after = Sound.pos_dft(result)
          below_after = after[10..200].abs.sum
          above_after = after[10000..20000].abs.sum

          below_db = Sound.linear_to_db(below_after / below_before)
          above_db = Sound.linear_to_db(above_after / above_before)

          # Within 0.1dB
          expect((below_db - gain).abs).to be <= 0.1
          expect((above_db).abs).to be <= 0.1
        end
      end
    end
  end

  context 'highshelf' do
    # Note: the cookbook uses shelf midpoint rather than approx 3dB point, so I
    # used 6.02dB and 1465.853Hz in an online calculator to match 1234Hz here.
    # Approximate ratio is 1.18788735818 higher for this particular high shelf.
    #
    # Used bin/find_biquad.rb plus a bit of manual tweaking to find the value
    it 'produces the expected transfer function for 1234/43210/Q.7/G6' do
      biquad = MB::Sound::Filter::Biquad.new(
        1.9138104220953347,
        -3.420231952756624,
        1.545793526548647,
        -1.7003917748937079,
        0.7397637707810658
      )

      cookbook = MB::Sound::Filter::Cookbook.new(:highshelf, 43210, 1234, db_gain: 6.02, quality: 0.7071)

      freqs = Numo::DComplex.logspace(Math.log2(20), Math.log2(20000), 10, 2)

      cb_resp = freqs.map { |f|
        cookbook.response(f.abs)
      }

      bq_resp = freqs.map { |f|
        biquad.response(f.abs)
      }

      magratio = cb_resp.abs / bq_resp.abs
      phaseratio = cb_resp.arg / bq_resp.arg

      expect((magratio - 1.0).abs.max).to be <= 0.00005
      expect((phaseratio - 1.0).abs.max).to be <= 0.0001 # relaxed constraint due to frequency offset
    end

    it 'produces the right coefficients for 1234/43210/Q.7/G6' do
      coeff = [
        1.9138104220953347,
        -3.420231952756624,
        1.545793526548647,
        -1.7003917748937079,
        0.7397637707810658
      ]

      result = MB::Sound::Filter::Cookbook.new(:highshelf, 43210, 1234, db_gain: 6.02, quality: 0.7071)

      ratios = result.coefficients.zip(coeff).map { |a, b| a == b ? 1 : (a / b).round(5) } # using weaker rounding due to frequency offset

      expect(ratios).to eq([1] * 5)
    end
  end

  context 'allpass' do
    it 'produces a gain of 1 for 1234/43210/Q.7' do
      cookbook = MB::Sound::Filter::Cookbook.new(:allpass, 43210, 1234, quality: 0.7071)
      freqs = Numo::DComplex.logspace(Math.log2(20), Math.log2(20000), 10, 2)
      cb_resp = freqs.map { |f| cookbook.response(f.abs) }
      expect((cb_resp.abs - 1.0).abs.max).to be <= 0.00001
    end

    it 'produces a phase discontinuity around center frequency' do
      cookbook = MB::Sound::Filter::Cookbook.new(:allpass, 43210, 1234, quality: 0.7071)
      below = cookbook.response(1233)
      above = cookbook.response(1235)
      expect(below.arg.positive?).not_to eq(above.arg.positive?)
    end
  end
end
