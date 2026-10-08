require 'numo/pocketfft'

RSpec.describe(MB::Sound::Filter::SVF, :aggregate_failures) do
  SVFF = MB::Sound::Filter::SVF unless defined?(SVFF)
  CBF = MB::Sound::Filter::Cookbook unless defined?(CBF)

  # Gain in dB for the types that take one
  def type_gain(type)
    SVFF::GAIN_TYPES.include?(type) ? 6.0 : nil
  end

  describe 'C and Ruby versions' do
    let(:n) { 4801 }
    let(:noise) { MB::Sound.with_seed(3) { Numo::SFloat.cast(MB::Sound.noise.sample(n)) } }
    # Cutoffs from below 0 to above Nyquist, qualities through 0, gains through 0
    let(:cutoffs) { Numo::DFloat.new(n).seq.map { |i| 25000 * Math.sin(i * 0.003)**2 - 300 } }
    let(:qualities) { Numo::SFloat.new(n).seq.map { |i| 3 * Math.sin(i * 0.0021)**2 - 0.1 } }
    let(:gains) { Numo::SFloat.new(n).seq.map { |i| 4 * Math.sin(i * 0.0011)**2 } }

    SVFF::FILTER_TYPES.each_with_index do |type, id|
      it "give identical samples for #{type} with modulated parameters" do
        s1 = [0.0, 0.0]
        s2 = [0.0, 0.0]
        [0...800, 800...801, 801...2400, 2400...4801].each do |r|
          c = MB::Sound::FastFilter.svf(noise[r].dup, cutoffs[r], qualities[r], gains[r], id, s1, 48000)
          ruby = SVFF.process_ruby(noise[r].dup, cutoffs[r], qualities[r], gains[r], id, s2, 48000)
          expect(c).to eq(ruby)
          expect(s1).to eq(s2)
        end
        expect(s1.all?(&:finite?)).to eq(true)
      end

      it "give identical samples for #{type} with constant parameters and NaN inputs" do
        s1 = [0.0, 0.0]
        s2 = [0.0, 0.0]
        c = MB::Sound::FastFilter.svf(noise.dup, 1234.5, 0.7, nil, id, s1, 44100)
        ruby = SVFF.process_ruby(noise.dup, 1234.5, 0.7, nil, id, s2, 44100)
        expect(c).to eq(ruby)

        nan = Numo::SFloat.new(n).fill(Float::NAN)
        c = MB::Sound::FastFilter.svf(noise.dup, nan, nan, nan, id, s1, 44100)
        ruby = SVFF.process_ruby(noise.dup, nan, nan, nan, id, s2, 44100)
        expect(c).to eq(ruby)
        expect(c.isfinite.all?).to eq(true)
        expect(s1).to eq(s2)
      end
    end

    it 'filters an inplace SFloat in place and copies others' do
      buf = noise.dup.inplace!
      out = MB::Sound::FastFilter.svf(buf, 500, 1, nil, 0, [0.0, 0.0], 48000)
      expect(out).to equal(buf)

      buf = noise.dup
      out = MB::Sound::FastFilter.svf(buf, 500, 1, nil, 0, [0.0, 0.0], 48000)
      expect(out).not_to equal(buf)
      expect(buf).to eq(noise)
    end

    it 'raises for bad arguments' do
      expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, 9, [0.0, 0.0], 48000) }.to raise_error(ArgumentError, /type/)
      expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, 0, [0.0], 48000) }.to raise_error(ArgumentError, /state/)
      expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, 0, [0.0, 0.0], 0) }.to raise_error(ArgumentError, /rate/)
      expect { MB::Sound::FastFilter.svf(noise, noise[0..5], 1, nil, 0, [0.0, 0.0], 48000) }.to raise_error(ArgumentError, /length/)
    end
  end

  describe 'static responses' do
    let(:omegas) { Numo::DFloat.linspace(0.0005, 3.1, 2000) }

    SVFF::FILTER_TYPES.each do |type|
      [[100, 0.5], [1000, 0.7071], [5000, 4], [20000, 0.9]].each do |hz, q|
        it "#{type} at #{hz} Hz, Q #{q} has the cookbook response (analytic)" do
          svf = SVFF.new(type, 48000, hz, quality: q, db_gain: type_gain(type))
          cb = CBF.new(type, 48000, hz, quality: q, db_gain: type_gain(type))
          # The kernel's tan approximation (FourPole.tan) is exact to about
          # 1e-16 at low frequencies and 4e-7 relative near 0.49 fs
          expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < (hz > 10000 ? 1e-7 : 1e-10)
        end
      end

      it "#{type} filters with the cookbook response (measured from the impulse response)" do
        svf = SVFF.new(type, 48000, 2000, quality: 3, db_gain: type_gain(type))
        cb = CBF.new(type, 48000, 2000, quality: 3, db_gain: type_gain(type))
        imp = Numo::SFloat.zeros(16384)
        imp[0] = 1
        measured = Numo::Pocketfft.rfft(Numo::DFloat.cast(svf.process(imp)))
        expected = cb.response(Numo::DFloat.linspace(0, Math::PI, measured.length))
        # float32 output: errors around 1e-7 of full scale
        expect((measured - expected).abs.max).to be < 1e-4
      end

      it "#{type} nulls against the cookbook biquad on noise (float32 rounding only)" do
        noise = MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) }
        svf = SVFF.new(type, 48000, 700, quality: 1.5, db_gain: type_gain(type))
        cb = CBF.new(type, 48000, 700, quality: 1.5, db_gain: type_gain(type))
        a = svf.process(noise.dup)
        b = cb.process(noise.dup)
        residual_db = 20 * Math.log10((a - b).abs.max / b.abs.max)
        expect(residual_db).to be < -100
      end
    end

    it 'converts a bandwidth to a quality like the cookbook' do
      svf = SVFF.new(:peak, 48000, 3000, bandwidth_oct: 0.5, db_gain: -10)
      cb = CBF.new(:peak, 48000, 3000, bandwidth_oct: 0.5, db_gain: -10)
      expect(svf.quality).to be_within(1e-12).of(cb.quality)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'converts a shelf slope to a quality like the cookbook' do
      svf = SVFF.new(:lowshelf, 48000, 300, shelf_slope: 1, db_gain: 8)
      cb = CBF.new(:lowshelf, 48000, 300, shelf_slope: 1, db_gain: 8)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'can be made from a Cookbook filter' do
      cb = CBF.new(:highpass, 44100, 440, quality: 3)
      svf = SVFF.from_cookbook(cb)
      expect(svf.filter_type).to eq(:highpass)
      expect(svf.sample_rate).to eq(44100)
      expect(svf.cutoff).to eq(440)
      expect(svf.quality).to eq(3)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'raises for missing gains and unknown types' do
      expect { SVFF.new(:peak, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /gain/)
      expect { SVFF.new(:lowshelf, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /gain/)
      expect { SVFF.new(:bogus, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /type/)
      expect { SVFF.new(:lowpass, 48000, 1000) }.to raise_error(ArgumentError, /quality/)
    end
  end

  describe '#reset' do
    it 'sets the steady state for a constant input' do
      [:lowpass, :highpass, :lowshelf, :highshelf, :notch].each do |type|
        f = SVFF.new(type, 48000, 500, quality: 2, db_gain: type_gain(type))
        steady = f.reset(0.5)
        out = f.process(Numo::SFloat.new(100).fill(0.5))
        expect(out.to_a).to all_be_within(1e-6).of_array([steady] * 100)
        expect(steady).to be_within(1e-9).of(0.5 * f.response(0).real)
      end
    end
  end

  describe 'parameter changes' do
    let(:sine) { Numo::SFloat.new(48000).seq.map { |i| Math.sin(i * 2 * Math::PI * 220 / 48000) } }

    it 'stays bounded with no DC bump when the cutoff dives toward 0 Hz and back' do
      # 3400 Hz down to 0 (and below) and back up within 50 ms
      cut = Numo::SFloat.new(48000).seq.map { |i|
        t = i / 48000.0
        t < 0.2 ? 3400 : (t < 0.25 ? 3400 * Math.cos((t - 0.2) * 20 * Math::PI) : 3400)
      }
      out = SVFF.new(:lowpass, 48000, 3400, quality: 0.7071).dynamic_process(sine.dup, cutoff: cut, quality: 0.7071)
      expect(out.abs.max).to be < 1.1
    end

    it 'stays stable at the lowest and highest cutoffs and very high quality' do
      [0, 1, 23999, 1e9].each do |fc|
        f = SVFF.new(:bandpass_skirt, 48000, fc, quality: 1000)
        out = f.process(sine.dup)
        expect(out.isfinite.all?).to eq(true)
        expect(f.state.all?(&:finite?)).to eq(true)
      end
    end

    it 'keeps the last parameter values for #process' do
      f = SVFF.new(:peak, 48000, 1000, quality: 1, db_gain: 3)
      f.dynamic_process(sine[0...100].dup, cutoff: Numo::SFloat.linspace(1000, 2000, 100), quality: 3, gain: Numo::SFloat[*[2.0] * 100])
      expect(f.cutoff).to eq(2000)
      expect(f.quality).to eq(3)
      expect(f.gain).to eq(2)
    end

    it 'gives the same samples through the Ruby mirror method' do
      a = SVFF.new(:lowshelf, 48000, 200, quality: 0.7, db_gain: 6)
      b = SVFF.new(:lowshelf, 48000, 200, quality: 0.7, db_gain: 6)
      cut = Numo::SFloat.linspace(200, 2000, 1000)
      expect(a.dynamic_process(sine[0...1000].dup, cutoff: cut, quality: 0.7)).to eq(b.dynamic_process_ruby(sine[0...1000].dup, cutoff: cut, quality: 0.7))
      expect(a.state).to eq(b.state)
    end
  end

  it 'changes its sample rate' do
    f = SVFF.new(:lowpass, 48000, 20000, quality: 1)
    f.sample_rate = 22050
    expect(f.sample_rate).to eq(22050)
    expect(f.cutoff).to eq(22050 * 0.49)
  end
end
