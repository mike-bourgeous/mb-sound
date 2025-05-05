# This is the C extension from ext/mb/sound/fast_resample/
RSpec.describe(MB::Sound::FastResample, :aggregate_failures) do
  let(:converter_mode) { nil }
  let(:r_half) { MB::Sound::FastResample.new(0.5, converter_mode) { |s| Numo::SFloat.zeros(s) } }
  let(:r_double) { MB::Sound::FastResample.new(2, converter_mode) { |s| Numo::SFloat.zeros(s) } }

  describe '#initialize' do
    it 'raises an error if the rate ratio is too small' do
      expect { MB::Sound::FastResample.new(257) { } }.to raise_error(ArgumentError, /ratio.*<= 256/)
      expect { MB::Sound::FastResample.new(Float::INFINITY) { } }.to raise_error(ArgumentError, /ratio.*<= 256/)
    end

    it 'raises an error if the rate ratio is too large' do
      expect { MB::Sound::FastResample.new(0.999 / 256.0) { } }.to raise_error(ArgumentError, /ratio.*>= 1.256/)
      expect { MB::Sound::FastResample.new(-1) { } }.to raise_error(ArgumentError, /ratio.*>= 1.256/)
    end

    it 'raises an error if the rate ratio is not a number' do
      expect { MB::Sound::FastResample.new(Float::NAN) { } }.to raise_error(ArgumentError, /ratio.*NaN/)
    end

    it 'raises an error if no block was given' do
      expect { MB::Sound::FastResample.new(1) }.to raise_error(/block/)
    end

    it 'succeeds when given a reasonable ratio' do
      expect { MB::Sound::FastResample.new(Math::PI) { } }.not_to raise_error
      expect { MB::Sound::FastResample.new(0.1) { } }.not_to raise_error
    end

    it 'defaults to the best sinc interpolator' do
      expect(MB::Sound::FastResample.new(1){}.mode_id).to eq(0)
    end

    context 'with a resampling mode parameter' do
      it 'falls back to best sinc if mode is nil' do
        r = MB::Sound::FastResample.new(1, nil) { }
        expect(r.mode_id).to eq(0)
      end

      it 'supports :libsamplerate_best' do
        r = MB::Sound::FastResample.new(1, :libsamplerate_best) { }
        expect(r.mode_id).to eq(0)
      end

      it 'supports :libsamplerate_fastest' do
        r = MB::Sound::FastResample.new(1, :libsamplerate_fastest) { }
        expect(r.mode_id).to eq(2)
      end

      it 'supports :libsamplerate_linear' do
        r = MB::Sound::FastResample.new(1, :libsamplerate_linear) { }
        expect(r.mode_id).to eq(4)
      end

      it 'supports :libsamplerate_zoh' do
        r = MB::Sound::FastResample.new(1, :libsamplerate_zoh) { }
        expect(r.mode_id).to eq(3)
      end

      it 'converts Strings to Symbols' do
        r = MB::Sound::FastResample.new(1, "libsamplerate_fastest") { }
        expect(r.mode_id).to eq(2)
      end

      it 'accepts libsamplerate integer IDs' do
        r = MB::Sound::FastResample.new(1, 1) { }
        expect(r.mode_id).to eq(1)
        expect(r.mode_name).to eq(:"Medium Sinc Interpolator")
      end

      it 'raises an error for an unsupported name' do
        expect { MB::Sound::FastResample.new(0.5, :invalid_name_forever) { } }.to raise_error(/Unsupported.*invalid_name/)
      end

      it 'raises an error for an unsupported integer' do
        expect { MB::Sound::FastResample.new(0.5, -367) { } }.to raise_error(/Unsupported.*-367/)
      end

      MB::Sound::FastResample::CONVERTER_IDS.each do |name, id|
        it "supports #{name.inspect}" do
          r = MB::Sound::FastResample.new(1, name) { }
          expect(r.mode_id).to eq(id)
        end
      end
    end
  end

  describe '#read' do
    shared_examples_for 'a working libsamplerate wrapper' do
      it 'can read zeros' do
        result = r_half.read(100)
        expect(result.length).to eq(100)
        expect(result.abs.max).to eq(0)
      end

      it 'can read ones' do
        # TODO: Better way of changing the callback for tests
        r_half.instance_variable_set(:@callback, ->(size) { Numo::SFloat.ones(size) })

        result = r_half.read(100)
        expect(result.length).to eq(100)
        expect((result - 1).abs.max).to be_between(0, 0.5)
        expect(result.sum / result.length - 1).to be_between(-1e-2, 1e-2)
      end

      it 'can handle a subset view from the read block' do
        # TODO: Better way of changing the callback for tests
        r_double.instance_variable_set(:@callback, ->(size) { Numo::SFloat.zeros(size).concatenate(Numo::SFloat.ones(size))[0...size] })

        result = r_double.read(100)
        expect(result.length).to eq(100)
        10.times do
          expect(result.abs.max).to eq(0) # Never reaches the ones after the end
        end
      end

      it 'can grow the internal buffer' do
        result = r_half.read(10)
        expect(result.length).to eq(10)

        result = r_half.read(100000)
        expect(result.length).to eq(100000)

        result = r_half.read(10)
        expect(result.length).to eq(10)
      end

      pending 'handles short read'
      pending 'handles zero size at end of stream'
      pending 'handles nil at end of stream'
    end

    MB::Sound::FastResample::CONVERTER_IDS.each do |name, id|
      context "when mode is #{name.inspect} (ID=#{id})" do
        let(:converter_mode) { name }

        it 'has the correct mode' do
          expect(r_half.mode_id).to eq(id)
          expect(r_double.mode_id).to eq(id)
        end

        it_behaves_like 'a working libsamplerate wrapper'
      end
    end

    context 'with the ZOH interpolator' do
      it 'duplicates values as expected based on ratio' do
        data = Numo::SFloat[1, 2, 3, -4, -5]
        arrinput = MB::Sound::ArrayInput.new(data: data)
        r = MB::Sound::FastResample.new(4, :libsamplerate_zoh, &arrinput.method(:sample))
        expect(r.read(1)).to eq(Numo::SFloat[1])
        expect(r.read(3)).to eq(Numo::SFloat.ones(3));
        expect(r.read(6)).to eq(Numo::SFloat[2, 2, 2, 2, 3, 3])
      end
    end
  end
end
