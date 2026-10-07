# ITU-R BS.1770-4 loudness (MB::Sound::Loudness, MB::Sound.loudness).
#
# The conformance cases are generated from the descriptions in EBU Tech 3341
# (loudness meters, "EBU Mode" minimum requirements) and EBU Tech 3342
# (loudness range), not read from the EBU's test files: stereo sines at the
# given dBFS (peak) levels, with the phase continuing across level changes.
RSpec.describe(MB::Sound::Loudness, :aggregate_failures) do
  # Sine segments [[dBFS, seconds], ...] on every channel at +freq+ Hz.
  def segments(list, freq: 1000, rate: 48000)
    total = list.sum { |_, s| (s * rate).round }
    t = Numo::DFloat.new(total).seq / rate
    gain = Numo::DFloat.zeros(total)
    pos = 0
    list.each do |db, seconds|
      n = (seconds * rate).round
      gain[pos...(pos + n)] = db ? 10.0 ** (db / 20.0) : 0
      pos += n
    end
    Numo::NMath.sin(t * (2 * Math::PI * freq)) * gain
  end

  def stereo(list, **kwargs)
    x = segments(list, **kwargs)
    [x, x.dup]
  end

  describe '.k_weighting' do
    it 'reproduces the BS.1770 coefficient tables at 48 kHz' do
      shelf, hp = MB::Sound::Loudness.k_weighting(48000)

      expected_shelf = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
      expected_hp = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]

      shelf.coefficients.zip(expected_shelf).each { |c, e| expect(c).to be_within(1e-12).of(e) }
      hp.coefficients.zip(expected_hp).each { |c, e| expect(c).to be_within(1e-12).of(e) }
    end

    it 'has the documented response (+0.691 dB at 997 Hz, +4 dB shelf, RLB high-pass)' do
      expect(MB::Sound::Loudness.k_weighting_db(997)).to be_within(0.001).of(0.691)
      expect(MB::Sound::Loudness.k_weighting_db(10000)).to be_within(0.05).of(4.04)
      expect(MB::Sound::Loudness.k_weighting_db(20000)).to be_within(0.05).of(4.04)
      expect(MB::Sound::Loudness.k_weighting_db(2000)).to be_within(0.05).of(3.07)
      expect(MB::Sound::Loudness.k_weighting_db(100)).to be_within(0.05).of(-1.13)
      expect(MB::Sound::Loudness.k_weighting_db(38)).to be_within(0.05).of(-6.0)
      expect(MB::Sound::Loudness.k_weighting_db(20)).to be_within(0.05).of(-13.28)
    end

    # The bilinear transform warps each rate a little differently (as in
    # libebur128 and ffmpeg); about 0.03 dB at most from 20 Hz to 10 kHz.
    it 'keeps the response at other sample rates' do
      [44100, 96000, 32000].each do |rate|
        [20, 38, 100, 997, 2000, 10000].each do |f|
          expect(MB::Sound::Loudness.k_weighting_db(f, sample_rate: rate)).to be_within(0.05).of(MB::Sound::Loudness.k_weighting_db(f))
        end
      end
    end
  end

  describe 'EBU Tech 3341 cases' do
    it 'case 1: stereo 1 kHz at -23 dBFS reads -23.0 LUFS (M, S, I)' do
      r = MB::Sound.loudness(stereo([[-23, 20]]))
      expect(r.integrated).to be_within(0.1).of(-23)
      expect(r.momentary_max).to be_within(0.1).of(-23)
      expect(r.short_term_max).to be_within(0.1).of(-23)
      expect(r.momentary.to_a.last).to be_within(0.1).of(-23)
      expect(r.short_term.to_a.last).to be_within(0.1).of(-23)
    end

    it 'case 2: stereo 1 kHz at -33 dBFS reads -33.0 LUFS' do
      r = MB::Sound.loudness(stereo([[-33, 20]]))
      expect(r.integrated).to be_within(0.1).of(-33)
      expect(r.momentary_max).to be_within(0.1).of(-33)
      expect(r.short_term_max).to be_within(0.1).of(-33)
    end

    it '997 Hz at -23 dBFS reads -23.0 LUFS (the K-weighting reference frequency)' do
      r = MB::Sound.loudness(stereo([[-23, 20]], freq: 997))
      expect(r.integrated).to be_within(0.01).of(-23)
    end

    it 'case 3: -36/-23/-36 dBFS (10/60/10 s) reads -23.0 (relative gate)' do
      r = MB::Sound.loudness(stereo([[-36, 10], [-23, 60], [-36, 10]]))
      expect(r.integrated).to be_within(0.1).of(-23)
    end

    it 'case 4: -72/-36/-23/-36/-72 dBFS (10/10/60/10/10 s) reads -23.0 (both gates)' do
      r = MB::Sound.loudness(stereo([[-72, 10], [-36, 10], [-23, 60], [-36, 10], [-72, 10]]))
      expect(r.integrated).to be_within(0.1).of(-23)
    end

    it 'case 5: -26/-20/-26 dBFS (20/20.1/20 s) reads -23.0' do
      r = MB::Sound.loudness(stereo([[-26, 20], [-20, 20.1], [-26, 20]]))
      expect(r.integrated).to be_within(0.1).of(-23)
    end

    it 'case 6: 5.0 channels at -28/-28/-24/-30/-30 dBFS read -23.0 (surround weights)' do
      data = [-28, -28, -24, -30, -30].map { |db| segments([[db, 20]]) }
      r = MB::Sound.loudness(data)
      expect(r.integrated).to be_within(0.1).of(-23)
      expect(r.weights).to eq([1.0, 1.0, 1.0, 1.41, 1.41])
    end

    it 'case 9: alternating 1.34 s at -20 dBFS and 1.66 s at -30 dBFS gives a steady short-term -23.0' do
      r = MB::Sound.loudness(stereo([[-20, 1.34], [-30, 1.66]] * 5))
      expect(r.short_term.length).to be > 100
      expect(r.short_term.to_a.min).to be_within(0.1).of(-23)
      expect(r.short_term.to_a.max).to be_within(0.1).of(-23)
    end

    [0, 0.05, 0.123, 0.987].each do |offset|
      it "short-term max of a 3 s -23 dBFS burst after #{offset} s of silence is -23.0" do
        r = MB::Sound.loudness(stereo([[nil, 1 + offset], [-23, 3], [nil, 1]]))
        expect(r.short_term_max).to be_within(0.1).of(-23)
      end

      it "momentary max of a 0.4 s -23 dBFS burst after #{offset} s of silence is -23.0" do
        r = MB::Sound.loudness(stereo([[nil, 1 + offset], [-23, 0.4], [nil, 1]]))
        expect(r.momentary_max).to be_within(0.1).of(-23)
      end
    end

    it 'measures 44.1 kHz audio the same way' do
      r = MB::Sound.loudness(stereo([[-23, 20]], rate: 44100), sample_rate: 44100)
      expect(r.integrated).to be_within(0.1).of(-23)
      expect(r.sample_rate).to eq(44100)
    end
  end

  describe 'EBU Tech 3342 loudness range cases' do
    {
      1 => [[[-20, 20], [-30, 20]], 10],
      2 => [[[-20, 20], [-15, 20]], 5],
      3 => [[[-40, 20], [-20, 20]], 20],
      4 => [[[-50, 20], [-35, 20], [-20, 20], [-35, 20], [-50, 20]], 15],
    }.each do |number, (list, expected)|
      it "case #{number}: #{list.map(&:first).join('/')} dBFS gives #{expected} LU" do
        r = MB::Sound.loudness(stereo(list), true_peak: false)
        expect(r.range).to be_within(1).of(expected)
        expect(r.lra).to be_within(0.1).of(expected)
      end
    end
  end

  describe 'gating' do
    # The three blocks straddling the level change pass both gates, so the
    # result is about 0.06 LU under -23.
    it 'ignores blocks below the -70 LUFS absolute gate' do
      r = MB::Sound.loudness(stereo([[-23, 10], [-75, 60]]), true_peak: false)
      expect(r.integrated).to be_within(0.1).of(-23)

      r = MB::Sound.loudness(stereo([[-69, 10], [-75, 60]]), true_peak: false)
      expect(r.integrated).to be_within(0.1).of(-69)
      r = MB::Sound.loudness(stereo([[-71, 10], [-75, 60]]), true_peak: false)
      expect(r.integrated).to eq(-Float::INFINITY)
    end

    it 'ignores blocks more than 10 LU below the absolutely gated loudness' do
      r = MB::Sound.loudness(stereo([[-23, 20], [-40, 20]]), true_peak: false)
      expect(r.integrated).to be_within(0.05).of(-23)
      expect(r.relative_threshold).to be_within(0.5).of(-23 - 3 - 10)
    end

    it 'averages energy (not loudness) of blocks within the gates' do
      r = MB::Sound.loudness(stereo([[-20, 20], [-26, 20]]), true_peak: false)
      expected = 10 * Math.log10((10 ** -2.0 + 10 ** -2.6) / 2)
      expect(r.integrated).to be_within(0.05).of(expected)
    end

    it 'returns -Infinity for silence and for audio shorter than one 400 ms block' do
      r = MB::Sound.loudness([Numo::DFloat.zeros(48000)] * 2)
      expect(r.integrated).to eq(-Float::INFINITY)
      expect(r.range).to eq(0)

      r = MB::Sound.loudness(stereo([[-23, 0.39]]))
      expect(r.integrated).to eq(-Float::INFINITY)
      expect(r.momentary_max).to eq(-Float::INFINITY)
      expect(r.true_peak).to be_within(0.05).of(-23)
    end
  end

  describe 'channel weights' do
    it 'weighs mono 1.0, reading 3 LU below the same signal on two channels' do
      x = segments([[-23, 5]])
      expect(MB::Sound.loudness(x).integrated).to be_within(0.05).of(-26)
      expect(MB::Sound.loudness(x, weights: [2.0]).integrated).to be_within(0.05).of(-23)
    end

    it 'excludes the LFE channel of 5.1' do
      x = segments([[-23, 5]])
      silent = Numo::DFloat.zeros(x.length)
      loud = segments([[0, 5]], freq: 60)
      r = MB::Sound.loudness([x, x, silent, loud, silent, silent])
      expect(r.integrated).to be_within(0.05).of(-23)
      expect(r.true_peak).to be_within(0.05).of(0)
    end

    it 'accepts custom weights' do
      x = segments([[-23, 5]])
      r = MB::Sound.loudness([x, x], weights: [1.0, 0.0])
      expect(r.integrated).to be_within(0.05).of(-26)
    end

    it 'raises for the wrong number of weights' do
      expect { MB::Sound.loudness([Numo::DFloat.zeros(10)] * 2, weights: [1.0]) }.to raise_error(ArgumentError, /weights/)
    end
  end

  describe 'true peak' do
    it 'finds the inter-sample peak of a quarter-rate sine at 45 degrees' do
      t = Numo::DFloat.new(48000).seq
      x = Numo::NMath.sin(t * (Math::PI / 2) + Math::PI / 4)
      r = MB::Sound.loudness([x, x])
      expect(r.sample_peak).to be_within(0.01).of(-3.01)
      expect(r.true_peak).to be_within(0.2).of(0) # EBU Tech 3341: +0.2/-0.4 dB
    end

    # BS.1770-4's example filter is within about +0.2/-0.2 dB to 20 kHz;
    # the sines fade in and out, since abrupt starts and stops overshoot
    # (a 15 kHz sine cut off at full scale really peaks near +0.4 dBTP).
    [997, 5000, 15000, 19000].each do |f|
      it "reads a full-scale #{f} Hz sine within +0.2/-0.4 dB of 0 dBTP" do
        x = segments([[0, 1]], freq: f)
        x[0...480] *= Numo::DFloat.new(480).seq / 480
        x[-480..] *= (Numo::DFloat.new(480).seq / 480).reverse
        r = MB::Sound.loudness([x, x])
        expect(r.true_peak).to be_between(-0.4, 0.2)
        expect(r.true_peak).to be >= r.sample_peak
      end
    end

    it 'reports each channel' do
      x = segments([[-6, 1]])
      r = MB::Sound.loudness([x, x * 0.5])
      expect(r.true_peaks[0]).to be_within(0.05).of(-6)
      expect(r.true_peaks[1]).to be_within(0.05).of(-12)
    end

    it 'includes the interpolation tail after the last sample' do
      tp = MB::Sound::Loudness::TruePeak.new
      tp.process(Numo::DFloat[0, 0, 0, 1])
      expect(tp.oversampled_peak).to be < 0.98
      expect(tp.peak).to eq(1.0)

      tp = MB::Sound::Loudness::TruePeak.new
      tp.process(Numo::DFloat[0, 0, 0, 1, -1])
      expect(tp.peak).to be > 1
    end

    it 'matches the Ruby mirror exactly (C kernel)' do
      x = Numo::DFloat.new(10011).rand(-1, 1)
      [0, 1, 7, 1000, 10000].each do |n|
        expect(MB::Sound::FastLoudness.true_peak(x, n)).to eq(MB::Sound::Loudness::TruePeak.oversampled_max_ruby(x, n))
      end

      # Non-contiguous views are copied
      v = x[(0..)%2]
      expect(MB::Sound::FastLoudness.true_peak(v, 100)).to eq(MB::Sound::Loudness::TruePeak.oversampled_max_ruby(v.dup, 100))
    end

    it 'rejects bad arguments in C' do
      expect { MB::Sound::FastLoudness.true_peak(Numo::SFloat.zeros(20), 5) }.to raise_error(ArgumentError, /DFloat/)
      expect { MB::Sound::FastLoudness.true_peak(Numo::DFloat.zeros(20), 10) }.to raise_error(ArgumentError, /Need/)
      expect { MB::Sound::FastLoudness.true_peak(Numo::DFloat.zeros(20), -1) }.to raise_error(ArgumentError, /negative/)
    end

    it 'gives the same result in any buffer sizes' do
      x = Numo::DFloat.new(5000).rand(-1, 1)
      whole = MB::Sound::Loudness::TruePeak.new.process(x)
      parts = MB::Sound::Loudness::TruePeak.new
      [1, 3, 11, 12, 500, 4473].each_with_object([0]) { |n, pos| parts.process(x[pos[0]...(pos[0] + n)]); pos[0] += n }
      expect(parts.peak).to eq(whole.peak)
      expect(parts.sample_peak).to eq(whole.sample_peak)
    end
  end

  describe MB::Sound::Loudness::Analyzer do
    it 'gives the same results for any buffer sizes' do
      l, r = stereo([[-20, 4], [-30, 3], [-25, 3]])
      r1 = described_class.new(channels: 2).process([l, r]).result

      a = described_class.new(channels: 2)
      pos = 0
      sizes = [1, 17, 480, 512, 4799, 48000].cycle
      while pos < l.length
        n = [sizes.next, l.length - pos].min
        a.process([l[pos...(pos + n)], r[pos...(pos + n)]])
        pos += n
      end
      r2 = a.result

      expect(r2.integrated).to be_within(1e-9).of(r1.integrated)
      expect(r2.range).to be_within(1e-9).of(r1.range)
      expect(r2.momentary_max).to be_within(1e-9).of(r1.momentary_max)
      expect(r2.true_peak).to eq(r1.true_peak)
      expect((r2.short_term - r1.short_term).abs.max).to be < 1e-9
    end

    it 'gives live momentary and short-term values' do
      a = described_class.new(channels: 2)
      expect(a.momentary).to eq(-Float::INFINITY)

      a.process(stereo([[-23, 0.4]]))
      expect(a.momentary).to be_within(0.1).of(-23)
      expect(a.short_term).to be_within(0.1).of(-23 + 10 * Math.log10(0.4 / 3))

      a.process(stereo([[-23, 3]]))
      expect(a.short_term).to be_within(0.1).of(-23)
      expect(a.integrated).to be_within(0.1).of(-23)
      expect(a.true_peak).to be_within(0.1).of(-23)
    end

    it 'does not modify its input' do
      l, r = stereo([[-23, 1]])
      l2 = l.dup
      described_class.new(channels: 2).process([l.inplace!, r])
      expect(l.not_inplace!).to eq(l2)
    end

    it 'accepts a bare NArray for one channel' do
      a = described_class.new(channels: 1)
      a.process(segments([[-23, 1]]))
      expect(a.momentary).to be_within(0.1).of(-26)
    end

    it 'uses 10 ms segments at 44.1 kHz and odd rates' do
      [44100, 22050].each do |rate|
        a = described_class.new(channels: 2, sample_rate: rate)
        a.process(stereo([[-23, 5]], rate: rate))
        expect(a.samples).to eq(5 * rate)
        expect(a.integrated).to be_within(0.1).of(-23)
      end
    end
  end

  describe MB::Sound::Loudness::Result do
    let(:result) { MB::Sound.loudness(stereo([[-20, 5]])) }

    it 'computes the gain to a target loudness' do
      expect(result.gain_to(-14)).to be_within(0.05).of(6)
    end

    it 'converts to a JSON-friendly Hash' do
      h = result.to_h
      expect(h[:integrated]).to be_within(0.05).of(-20)
      expect(h).not_to include(:momentary)
      expect(h[:true_peaks].length).to eq(2)

      h = result.to_h(series: true)
      expect(h[:momentary]).to be_a(Array)
      expect(h[:momentary].length).to eq(47)

      silent = MB::Sound.loudness([Numo::DFloat.zeros(100)])
      expect(silent.to_h[:integrated]).to eq(nil)
    end

    it 'describes itself' do
      expect(result.to_s).to match(/-20.0 LUFS integrated.*dBTP/)
    end
  end

  describe 'MB::Sound.loudness with files' do
    it 'reads a file at its own sample rate' do
      path = tmp_path('loud.flac')
      MB::Sound.write(path, stereo([[-23, 5]], rate: 44100).map { |c| Numo::SFloat.cast(c) }, sample_rate: 44100)
      r = MB::Sound.loudness(path)
      expect(r.sample_rate).to eq(44100)
      expect(r.channels).to eq(2)
      expect(r.integrated).to be_within(0.1).of(-23)
      expect(r.duration).to be_within(0.01).of(5)
    end

    it 'measures the test arp' do
      r = MB::Sound.loudness('spec/test_data/arp_a7.flac')
      expect(r.channels).to eq(2)
      expect(r.integrated).to be_finite
      expect(r.true_peak).to be >= r.sample_peak
    end

    it 'refuses graph nodes' do
      expect { MB::Sound.loudness(440.hz.sine) }.to raise_error(ArgumentError, /loudness_meter/)
    end
  end
end
