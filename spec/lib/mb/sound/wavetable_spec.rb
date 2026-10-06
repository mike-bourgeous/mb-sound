RSpec.describe(MB::Sound::Wavetable, aggregate_failures: true) do
  let(:w) { MB::Sound::Wavetable }

  # Harmonic amplitudes (DFloat, index h) of one cycle of +x+.
  def harmonic_amplitudes(x)
    x = Numo::DFloat.cast(x)
    Numo::Pocketfft.rfft(x).abs * (2.0 / x.length)
  end

  describe '.from_harmonics' do
    it 'keeps exact Fourier amplitudes and phases' do
      t = w.from_harmonics([1, 0.5, 0, 0.25], [0, Math::PI / 2, 0, 0], size: 64)
      x = t.frames[0, nil]
      phase = Numo::DFloat.new(64).seq / 64 * 2 * Math::PI
      expected = Numo::NMath.sin(phase) + 0.5 * Numo::NMath.cos(2 * phase) + 0.25 * Numo::NMath.sin(4 * phase)
      expect(x).to all_be_within(1e-6).of_array(expected)
    end

    it 'makes one level per octave by default, each oversampled 4x' do
      t = w.from_harmonics(Array.new(100, 0.01))
      expect(t.levels.map(&:bandwidth)).to eq([100, 50, 25, 12, 6, 3, 1].map(&:to_f))
      expect(t.levels.map(&:count)).to eq([1024, 512, 256, 128, 64, 32, 32])
      expect(t.levels.map { |l| l.data.shape }).to all(satisfy { |s| s[0] == 1 })
      expect(t.levels[0].data.shape[1]).to eq(1024 + 2 * w::GUARD)
    end

    it 'keeps only the harmonics of each level' do
      t = w.from_harmonics(w::Library.saw)
      t.levels(:cubic).each do |l|
        data = l.data[0, w::GUARD...(w::GUARD + l.count)]
        amps = harmonic_amplitudes(data)
        h = l.bandwidth.to_i
        expect(amps[1..h]).to all_be_within(1e-5).of_array(Numo::DFloat.cast(w::Library.saw(h)).abs)
        expect(amps[(h + 1)..].max).to be < 1e-5
      end
    end

    it 'stores levels for the optimal interpolator with its pre-emphasis' do
      t = w.from_harmonics(w::Library.saw)
      l = t.levels(:optimal)[2]
      data = l.data[0, w::GUARD...(w::GUARD + l.count)]
      amps = harmonic_amplitudes(data)[1..255]
      gains = w::Emphasis.gains(256, l.count)[1..255]
      expect(amps).to all_be_within(1e-5).of_array(Numo::DFloat.cast(w::Library.saw(255)).abs * gains)
      expect(gains[-1]).to be_within(0.01).of(1.13)
    end

    it 'can taper each level with Lanczos sigma factors' do
      t = w.from_harmonics(w::Library.saw, taper: :sigma)
      expect(t.taper).to eq(:sigma)
      l = t.levels(:cubic)[2]
      data = l.data[0, w::GUARD...(w::GUARD + l.count)]
      amps = harmonic_amplitudes(data)[1..255]
      x = Numo::DFloat.new(255).seq(1) * (Math::PI / 256)
      sigma = Numo::NMath.sin(x) / x
      expect(amps).to all_be_within(1e-5).of_array(Numo::DFloat.cast(w::Library.saw(255)).abs * sigma)

      # No Gibbs overshoot: the exact series peaks 18% high
      expect(t.levels(:cubic).map { |lv| lv.data.abs.max }.max).to be < 1.03
      expect(w.from_harmonics(w::Library.saw).levels(:cubic)[0].data.abs.max).to be > 1.15
      expect { w.from_harmonics([1], taper: :hann) }.to raise_error(ArgumentError, /taper/)
    end

    it 'wraps the guard samples around the cycle' do
      l = w[:saw].levels[3]
      d = l.data[0, nil]
      g = w::GUARD
      expect(d[0...g]).to eq(d[l.count...(l.count + g)])
      expect(d[(l.count + g)..]).to eq(d[g...(2 * g)])
    end

    it 'can make several frames' do
      t = w.from_harmonics([[1], [0, 1], [0, 0, 1]], size: 32)
      expect(t.frame_count).to eq(3)
      expect(t.frames.shape).to eq([3, 32])
      expect(harmonic_amplitudes(t.frames[2, nil])[3]).to be_within(1e-6).of(1)
    end

    it 'caps the harmonics at the size' do
      t = w.from_harmonics(Array.new(100, 0.1), size: 32)
      expect(t.harmonics).to eq(15)
    end

    it 'can use half-octave, custom, or no levels' do
      expect(w.from_harmonics(Array.new(64, 0.1), mips: :half_octave).levels.map(&:bandwidth)).to eq([64, 45, 32, 22, 16, 11, 8, 5, 4, 2, 1].map(&:to_f))
      expect(w.from_harmonics(Array.new(64, 0.1), mips: 4).levels.map(&:bandwidth)).to eq([64, 16, 4, 1].map(&:to_f))
      expect(w.from_harmonics(Array.new(64, 0.1), mips: [10, 64, 3]).levels.map(&:bandwidth)).to eq([64, 10, 3].map(&:to_f))

      t = w.from_harmonics(Array.new(64, 0.1), mips: false)
      expect(t).not_to be_mipped
      expect(t.levels.length).to eq(1)
      expect(t.interpolation).to eq(:cubic)
    end

    it 'uses the optimal interpolator by default with levels' do
      expect(w[:saw].interpolation).to eq(:optimal)
    end

    it 'can make an analytic (complex) table' do
      t = w.from_harmonics([1, 0.5], complex: true, size: 64)
      expect(t).to be_complex
      expect(t.frames).to be_a(Numo::SComplex)
      phase = Numo::DFloat.new(64).seq / 64 * 2 * Math::PI
      expect(t.frames[0, nil].real).to all_be_within(1e-6).of_array(Numo::NMath.sin(phase) + 0.5 * Numo::NMath.sin(2 * phase))
      expect(t.frames[0, nil].imag).to all_be_within(1e-6).of_array(-Numo::NMath.cos(phase) - 0.5 * Numo::NMath.cos(2 * phase))
      expect(t.levels[0].data).to be_a(Numo::SComplex)
    end

    it 'rejects unknown options' do
      expect { w.from_harmonics([1], mips: :decade) }.to raise_error(ArgumentError, /spacing/)
      expect { w.from_harmonics([1], mips: 1) }.to raise_error(ArgumentError, /above 1/)
      expect { w.from_harmonics([1], interpolation: :magic) }.to raise_error(ArgumentError, /interpolation/)
      expect { w.from_harmonics([[1], [1, 2]], [[0]]) }.to raise_error(ArgumentError)
    end
  end

  describe '.from_samples' do
    let(:cycle) { Numo::SFloat.new(64).seq.map { |v| Math.sin(2 * Math::PI * v / 64) + 0.3 * Math.sin(6 * Math::PI * v / 64) } }

    it 'accepts one cycle' do
      t = w.from_samples(cycle)
      expect(t.frame_count).to eq(1)
      expect(t.size).to eq(64)
      expect(t.harmonics).to eq(31)
      expect(t.value_at(0.25)).to be_within(1e-4).of(1 - 0.3)
    end

    it 'accepts several cycles as an Array of rows or a 2D NArray' do
      t = w.from_samples([cycle.to_a, (cycle * 0.5).to_a])
      expect(t.frame_count).to eq(2)
      expect(t.value_at(0.25, scan: 1)).to be_within(1e-4).of(0.35)
    end

    it 'aligns frames in time by default' do
      shifted = MB::M.rol(cycle, 20)
      t = w.from_samples(Numo::SFloat[cycle.to_a, shifted.to_a])
      expect(t.frames[1, nil]).to all_be_within(1e-5).of_array(cycle)

      t = w.from_samples(Numo::SFloat[cycle.to_a, shifted.to_a], align: false)
      expect(t.frames[1, nil]).to all_be_within(1e-6).of_array(shifted)
    end

    it 'can normalize frames' do
      t = w.from_samples(cycle * 3 + 1, normalize: true, mips: false)
      expect(t.frames.abs.max).to be_within(1e-6).of(1)
      expect(t.frames.mean).to be_within(1e-6).of(0)
    end

    it 'can make an unmipped table that reads the samples directly' do
      data = Numo::SFloat[1, -2, 3, -4]
      t = w.from_samples(data, mips: false)
      [0, 0.25, 0.5, 0.75].each_with_index do |ph, i|
        expect(t.value_at(ph, interpolation: :none)).to eq(data[i])
        expect(t.value_at(ph, interpolation: :linear)).to eq(data[i])
      end
      expect(t.value_at(0.125, interpolation: :linear)).to eq(-0.5)
      expect(t.value_at(0.875, interpolation: :linear)).to eq(-1.5)
    end

    context 'in sample mode' do
      let(:sound) { Numo::SFloat.new(1000).rand(-1, 1) }

      it 'needs a root' do
        expect { w.from_samples(sound, mode: :sample) }.to raise_error(ArgumentError, /root/)
      end

      it 'takes a root in Hz, a Pitch, or a Note' do
        expect(w.from_samples(sound, mode: :sample, root: 100).root).to eq(100)
        expect(w.from_samples(sound, mode: :sample, root: 220.hz).root).to eq(220)
        expect(w.from_samples(sound, mode: :sample, root: MB::Sound::A4).root).to be_within(1e-9).of(440)
      end

      it 'is a one-shot without a loop' do
        t = w.from_samples(sound, mode: :sample, root: 100)
        expect(t).to be_one_shot
        expect(t.loop).to be_nil
        expect(t.size).to eq(1000)
        expect(t.frames).to eq(sound)
      end

      it 'takes loops as ranges of samples or Lengths' do
        expect(w.from_samples(sound, mode: :sample, root: 100, loop: 100...200).loop).to eq(100...200)
        expect(w.from_samples(sound, mode: :sample, root: 100, loop: 100..199).loop).to eq(100...200)
        expect(w.from_samples(sound, mode: :sample, root: 100, loop: 100..).loop).to eq(100...1000)
        expect(w.from_samples(sound, mode: :sample, root: 100, loop: 0.001.seconds...0.01.seconds).loop).to eq(48...480)
        expect { w.from_samples(sound, mode: :sample, root: 100, loop: 200...100) }.to raise_error(ArgumentError, /loop/i)
      end

      it 'plays its own samples at the root pitch with the brightest level' do
        t = w.from_samples(sound, mode: :sample, root: 100)
        expect(t.value_at(100, increment: 1)).to be_within(1e-3).of(sound[100])
        expect(t.levels[0].rate).to eq(4)
      end

      it 'band-limits each level by an octave' do
        t = w.from_samples(sound, mode: :sample, root: 100)
        expect(t.levels.map(&:bandwidth)[0..2]).to eq([0.5, 0.25, 0.125])
        expect(t.speed(48000)).to eq(1.0 / 100)
      end

      it 'has a level for each loop level, holding one period' do
        t = w.from_samples(sound, mode: :sample, root: 100, loop: 200...600)
        expect(t.loop_levels.length).to eq(t.levels.length)
        expect(t.loop_levels[0].count).to eq(1600)
        expect(t.value_at(300, increment: 1)).to be_within(1e-3).of(sound[300])
      end
    end
  end

  describe '.from_function' do
    it 'calls the block for each frame with the phases and scan position' do
      calls = []
      t = w.from_function(frames: 3, size: 16) { |ph, s|
        calls << [ph.length, ph[0], ph[-1], s]
        Numo::NMath.sin(ph * 2 * Math::PI) * (1 + s)
      }
      expect(calls).to eq([[16, 0.0, 15.0 / 16, 0.0], [16, 0.0, 15.0 / 16, 0.5], [16, 0.0, 15.0 / 16, 1.0]])
      expect(t.frame_count).to eq(3)
      expect(t.value_at(0.25, scan: 1)).to be_within(1e-3).of(2)
    end

    it 'raises an error for the wrong length' do
      expect { w.from_function(size: 16) { [1, 2] } }.to raise_error(ArgumentError, /samples/)
    end
  end

  describe '.from_file' do
    it 'loads saved frames' do
      t = w.from_file('spec/test_data/short_wavetable.flac', align: false, mips: false)
      expect(t.frames.shape).to eq([3, 5])
      expect(t.name).to eq('short_wavetable.flac')
    end

    it 'loads a sound in sample mode, estimating its root' do
      t = w.from_file('sounds/piano_120hz_b2.flac', mode: :sample, loop: 12000...24000)
      expect(t.mode).to eq(:sample)
      expect(t.root).to be_within(2).of(120)
      expect(t.loop).to eq(12000...24000)
    end
  end

  describe '.[]' do
    it 'returns named tables from the library' do
      expect(w[:saw]).to be_a(w)
      expect(w[:saw]).to equal(w[:saw])
      expect(w[:ramp]).to equal(w[:saw])
      expect(w.names).to include(:saw, :square, :triangle, :sine, :organ, :basic, :pulses)
      expect { w[:nope] }.to raise_error(ArgumentError, /No wavetable named/)
    end

    it 'loads files and builds tables from samples' do
      expect(w['spec/test_data/short_wavetable.flac'].frame_count).to eq(3)
      expect(w[[0, 1, 0, -1]].size).to eq(4)
      expect(w[Numo::SFloat[[0, 1, 0, -1], [0, 1, 0, -1]]].frame_count).to eq(2)
    end

    it 'returns a Wavetable unchanged' do
      t = w[:sine]
      expect(w[t]).to equal(t)
    end

    it 'rejects other things' do
      expect { w[5] }.to raise_error(ArgumentError)
    end
  end

  describe '.register' do
    after { w.instance_variable_get(:@registry).delete(:spec_table) }

    it 'adds a lazily built table to the library' do
      built = 0
      w.register(:spec_table) { built += 1; w.from_harmonics([1, 1]) }
      expect(built).to eq(0)
      expect(w[:spec_table].harmonics).to eq(2)
      expect(w[:spec_table].name).to eq('spec_table')
      w[:spec_table]
      expect(built).to eq(1)
    end

    it 'can register a table' do
      w.register(:spec_table, [0, 1, 0, -1])
      expect(w[:spec_table].size).to eq(4)
    end
  end

  describe 'the library' do
    it 'has classic shapes that match the naive Tone shapes away from their edges' do
      { saw: :ramp, square: :square, triangle: :triangle }.each do |name, wave|
        [0.1, 0.2, 0.3, 0.6, 0.85].each do |ph|
          expect(w[name].value_at(ph)).to be_within(0.005).of(MB::Sound::Tone.value_at_ruby(wave, ph * 2 * Math::PI)), "#{name} at #{ph}"
        end
      end
    end

    it 'has a scannable table of basic shapes' do
      t = w[:basic]
      expect(t.frame_count).to eq(4)
      expect(t.value_at(0.25, scan: 0)).to be_within(1e-5).of(1)
      expect(t.value_at(0.25, scan: 1)).to be_within(0.02).of(0.5)
    end

    it 'scales tables without classic shapes to a peak of 1' do
      expect(w[:organ].frames.abs.max).to be_within(1e-6).of(1)
    end
  end

  describe '#thresholds' do
    it 'crossfades each level into the next over the top fifth of an octave below the ceiling' do
      t = w[:saw]
      hi, lo = t.thresholds(48000)
      top = 1 - 20000.0 / 48000
      expect(t.ceiling(48000)).to eq(top)
      expect(hi[0]).to eq(top / 1023)
      expect(lo[1]).to be_within(1e-12).of(hi[1] * 2**-0.2)
      expect(lo[-1]).to eq(hi[-1])
      expect(t.ceiling(32000)).to eq(0.5)
    end

    it 'gives levels without an audible step in level or brightness' do
      t = w[:saw]
      hi, _lo = t.thresholds(48000)
      [0.1, 0.37, 0.8].each do |ph|
        hi.to_a[0...-1].each do |h|
          below = t.value_at(ph, increment: h * (1 - 1e-9))
          above = t.value_at(ph, increment: h * (1 + 1e-9))
          expect(above).to be_within(1e-6).of(below)
        end
      end
    end
  end

  describe '#value_at' do
    it 'interpolates a sine accurately with every interpolator' do
      t = w[:sine]
      { none: 0.2, linear: 6e-3, cubic: 2e-4, optimal: 2e-5, sinc: 2e-5 }.each do |interp, tolerance|
        [0.1, 0.123, 0.5005, 0.9].each do |ph|
          expect(t.value_at(ph, interpolation: interp)).to be_within(tolerance).of(Math.sin(2 * Math::PI * ph)), "#{interp} at #{ph}"
        end
      end
    end

    it 'clamps scan positions' do
      t = w[:basic]
      expect(t.value_at(0.1, scan: -1)).to eq(t.value_at(0.1, scan: 0))
      expect(t.value_at(0.1, scan: 2)).to eq(t.value_at(0.1, scan: 1))
    end
  end

  describe '#save' do
    it 'saves frames that load again' do
      name = tmp_path('saved_table.flac')
      t = w.from_harmonics([[1], [0.5, 0.5]], size: 64)
      t.save(name)
      t2 = w.from_file(name, align: false)
      expect(t2.frames).to all_be_within(1e-4).of_array(t.frames)
    end

    it 'saves the settings and derived values, which load as defaults' do
      name = tmp_path('saved_settings.flac')
      t = w.from_harmonics(w::Library.square(100), mips: :half_octave, interpolation: :cubic, taper: :sigma, name: 'sq')
      t.save(name)

      info = {}
      MB::Sound.read(name, metadata_out: info)
      tags = w.table_metadata(info)
      t2 = w.from_file(name)
      expect(t2.name).to eq('sq')
      expect(t2.spacing).to eq(Math.sqrt(2))
      expect(t2.interpolation).to eq(:cubic)
      expect(t2.taper).to eq(:sigma)
      expect(t2.levels(:cubic)[2].data).to all_be_within(1e-5).of_array(t.levels(:cubic)[2].data)
      expect(t.metadata).to include(mode: 'cycle', frames: 1, period: 2048, aligned: 'false', taper: 'sigma', harmonics: 100)
      expect(tags).to include(period: 2048, frames: 1, harmonics: 100, spacing: Math.sqrt(2), interpolation: 'cubic', taper: 'sigma', name: 'sq')
    end

    it 'saves peaks above 1 with a scale' do
      name = tmp_path('saved_scaled.flac')
      t = w.from_harmonics(w::Library.saw, mips: false)
      expect(t.frames.abs.max).to be > 1.1
      t.save(name)
      t2 = w.from_file(name, mips: false)
      expect(t2.frames).to all_be_within(1e-5).of_array(t.frames)
    end

    it 'marks aligned frames so they are not aligned again' do
      name = tmp_path('saved_aligned.flac')
      cycle = Numo::SFloat.new(64).seq.map { |v| Math.sin(2 * Math::PI * v / 64) }
      t = w.from_samples(Numo::SFloat[cycle.to_a, MB::M.rol(cycle, 9).to_a])
      expect(t).to be_aligned
      t.save(name)
      t2 = w.from_file(name)
      expect(t2).to be_aligned
      expect(t2.metadata[:aligned]).to eq('true')
      expect(t2.frames).to all_be_within(1e-5).of_array(t.frames)
    end

    it 'saves where a sliced table came from' do
      name = tmp_path('saved_sliced.flac')
      allow($stderr).to receive(:puts)
      t = w.from_file('sounds/piano_120hz_b2.flac', slices: 4)
      expect(t.source_info[:frequency]).to be_within(2).of(120)
      t.save(name)
      t2 = w.from_file(name)
      expect(t2.source_info[:frequency]).to be_within(1e-6).of(t.source_info[:frequency])
      expect(t2.source_info[:note_name]).to eq(t.source_info[:note_name])
    end

    it 'saves sample mode tables with their root and loop' do
      name = tmp_path('saved_sample.flac')
      sound = Numo::SFloat.new(2000).rand(-1, 1)
      t = w.from_samples(sound, mode: :sample, root: 220, loop: 500...1500)
      t.save(name)
      t2 = w.from_file(name)
      expect(t2.mode).to eq(:sample)
      expect(t2.root).to eq(220)
      expect(t2.loop).to eq(500...1500)
      expect(t2.frames).to all_be_within(1e-5).of_array(sound)
    end
  end

  describe '#to_s' do
    it 'describes the table' do
      expect(w[:basic].to_s).to eq('basic (cycle, 4 frames, 10 levels)')
    end
  end
end
