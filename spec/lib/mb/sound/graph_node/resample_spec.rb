RSpec.describe(MB::Sound::GraphNode::Resample, :aggregate_failures) do
  # Compensate for lag by skipping leading zeroes and then selecting as many
  # whole wave cycles as possible.  If there are no zero crossings, then only
  # zero-skipping is applied.
  def select_whole_cycles(resampled, reference)
    resampled = MB::M.skip_leading(resampled) { |v| v.abs < 0.5 }
    reference = MB::M.skip_leading(reference) { |v| v.abs < 0.5 }

    resampled = MB::M.select_zero_crossings(resampled, nil) || resampled
    reference = MB::M.select_zero_crossings(reference, nil) || reference

    min_length = [resampled.length, reference.length].min
    return resampled.class[], reference.class[] if min_length == 0

    resampled = resampled[0...min_length]
    reference = reference[0...min_length]

    return resampled, reference
  end

  it 'can be created' do
    expect { MB::Sound::GraphNode::Resample.new(upstream: 150.hz.triangle, sample_rate: 12345) }.not_to raise_error
  end

  describe '#sample_rate=' do
    it 'does not change upstream sample rates' do
      a = 15.hz.at_rate(5432)
      b = a.resample(45678)

      b.sample_rate = 12345

      expect(a.sample_rate).to eq(5432)
      expect(b.sample_rate).to eq(12345)
    end

    it 'returns self when using the at_rate alias' do
      a = 10.hz.at_rate(12345).resample(54321)
      expect(a.at_rate(5243)).to equal(a)
    end
  end

  describe '#sample' do
    shared_examples_for 'a working resampler' do
      context 'when upsampling' do
        it 'can upsample with a reasonable noise floor' do
          resampled = 453.hz.at(1).at_rate(11376).resample(96000, mode: resample_mode).sample(24000)
          reference = 453.hz.at(1).at_rate(96000).sample(24000)
          resampled, reference = select_whole_cycles(resampled, reference)

          delta = resampled - reference

          expect(delta.abs.max).to be_between(-250.db, max_delta)
        end

        it 'does not matter what the upsampling chunk size is' do
          large_window = 47.hz.at(1).forever.at_rate(400).resample(17521, mode: resample_mode).sample(27000)
          small_window = 47.hz.at(1).forever.at_rate(400).resample(17521, mode: resample_mode).multi_sample(216, 125)
          large_window, small_window = select_whole_cycles(large_window, small_window)
          large_window = large_window[0...16000]
          small_window = small_window[0...16000]

          delta = large_window - small_window

          expect(delta).to all_be_within(1e-9).of_array(0)
        end

        it 'upsamples correctly when chunk sizes change' do
          node = 43.hz.at(1).forever.at_rate(432).resample(1700, mode: resample_mode)
          ref = 43.hz.at(1).forever.at_rate(432).resample(1700, mode: resample_mode)

          result = node.sample(129).dup.concatenate(node.multi_sample(242, 30)).concatenate(node.sample(111))
          expected = ref.sample(7500).dup

          result, expected = select_whole_cycles(result, expected)

          expect(result).to all_be_within(1e-9).of_array(expected)
        end

        it 'upsamples until the upstream returns nil' do
          node = 0.hz.square.at(1..1).at_rate(100).for(10).with_buffer(1).resample(280, mode: resample_mode)

          result = MB::M.trim(node.multi_sample(1, 3600)) { |v| v.abs < 0.5 }

          expect(result.length).to be_between(2300, 2801)
          expect(result[-10..-1].sum / 10).to be_within(1e-5).of(1)
          expect(result[-1]).to be_within(1e-5).of(1)
        end

        it 'upsamples end of stream within a buffer' do
          node = 0.hz.square.at(1..1).at_rate(100).for(10).with_buffer(10).resample(280, mode: resample_mode)

          result = MB::M.trim(node.multi_sample(195, 200)) { |v| v.abs < 0.5 }

          expect(result.length).to be_between(2300, 2801)
          expect(result[-10..-1].sum / 10).to be_within(1e-5).of(1)
          expect(result[-1]).to be_within(1e-5).of(1)
        end
      end

      context 'when downsampling' do
        it 'can downsample with a reasonable noise floor' do
          resampled = 157.hz.at(1).at_rate(96000).resample(5700, mode: resample_mode).sample(9600)
          reference = 157.hz.at(1).at_rate(5700).sample(9600)
          resampled, reference = select_whole_cycles(resampled, reference)

          delta = resampled - reference

          expect(delta.abs.max).to be_between(-250.db, max_delta)
        end

        it 'does not matter what the downsampling chunk size is' do
          large_window = 43.hz.at(1).forever.at_rate(17521).resample(400, mode: resample_mode).sample(27000)
          small_window = 43.hz.at(1).forever.at_rate(17521).resample(400, mode: resample_mode).multi_sample(216, 125)
          large_window, small_window = select_whole_cycles(large_window, small_window)
          large_window = large_window[0...16000]
          small_window = small_window[0...16000]

          delta = large_window - small_window

          expect(delta).to all_be_within(1e-9).of_array(0)
        end

        it 'downsamples correctly when chunk sizes change' do
          node = 43.hz.at(1).forever.at_rate(4320).resample(1700, mode: resample_mode)
          ref = 43.hz.at(1).forever.at_rate(4320).resample(1700, mode: resample_mode)

          result = node.sample(129).dup.concatenate(node.multi_sample(242, 30)).concatenate(node.sample(111))
          expected = ref.sample(7500).dup

          result, expected = select_whole_cycles(result, expected)

          expect(result).to all_be_within(1e-9).of_array(expected)
        end

        it 'downsamples until the upstream returns nil' do
          node = 0.hz.square.at(1..1).at_rate(1000).for(1).with_buffer(1).resample(280, mode: resample_mode)

          sample = node.multi_sample(1, 360)
          result = MB::M.trim(sample) { |v| v.abs < 0.5 }

          # Some resamplers (e.g. best sinc resampler) take a while to get
          # started so the length is shorter
          expect(result.length).to be_between(130, 281)
          expect(result[-10..-1].sum / 10).to be_within(1e-5).of(1)
          expect(result[-1]).to be_within(1e-5).of(1)
        end

        it 'downsamples end of stream within a buffer' do
          node = 0.hz.square.at(1..1).at_rate(1000).for(1).with_buffer(100).resample(280, mode: resample_mode)

          sample = node.multi_sample(195, 10)
          result = MB::M.trim(sample) { |v| v.abs < 0.5 }

          # Some resamplers (e.g. best sinc resampler) take a while to get
          # started so the length is shorter
          expect(result.length).to be_between(130, 281)
          expect(result[-10..-1].sum / 10).to be_within(1e-5).of(1)
          expect(result[-1]).to be_within(1e-5).of(1)
        end
      end
    end

    MB::Sound::GraphNode::Resample::MODES.each do |mode|
      context "when resampling mode is #{mode.inspect}" do
        let (:resample_mode) { mode }
        let (:max_delta) {
          # Zero-order hold is noisy so relax its reference delta limit
          resample_mode.to_s.downcase.include?('zoh') ? 0.25 : -30.db
        }

        it_behaves_like 'a working resampler'
      end
    end

    context 'with the default mode' do
      let (:resample_mode) { MB::Sound::GraphNode::Resample::DEFAULT_MODE }
      let (:max_delta) { -60.db }

      it_behaves_like 'a working resampler'
    end

    it 'gives the same results for different chunk sizes (from plot_resampler_window_delta.rb)' do
      d1 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: :ruby_zoh).sample(27000), 0)[0...16000]
      d2 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: :ruby_zoh).multi_sample(216, 125), 0)[0...16000]
      delta = d2.not_inplace! - d1.not_inplace!
      expect(delta.abs.max).to eq(0)
    end

    context 'using a sample counter to verify time linearity' do
      shared_examples_for 'zoh or linear' do
        let (:long_sample) {
          node.sample(600).dup
        }
        let (:random_sample) {
          node.multi_sample(7, 30).concatenate(node.sample(30)).concatenate(node.sample(3)).concatenate(node.sample(357))
        }
        let (:consistent_sample) {
          node.multi_sample(12, 50)
        }

        it 'has the expected output when sampling all at once' do
          sample, reference = select_whole_cycles(long_sample, expected)
          expect(sample).to all_be_within(tolerance).sigfigs.of_array(reference)
        end

        it 'has the expected output when sampling in random chunks' do
          sample, reference = select_whole_cycles(random_sample, expected)
          expect(sample).to all_be_within(tolerance).sigfigs.of_array(reference)
        end

        it 'has the expected output when sampling in consistent chunks' do
          sample, reference = select_whole_cycles(consistent_sample, expected)
          expect(sample).to all_be_within(tolerance).sigfigs.of_array(reference)
        end
      end

      shared_examples_for 'zoh' do
        let (:expected) { Numo::Int32.linspace(0, output_end, 200001) }
        it_behaves_like 'zoh or linear'
      end

      shared_examples_for 'linear' do
        let (:expected) { Numo::SFloat.linspace(0, output_end, 200001) }
        it_behaves_like 'zoh or linear'
      end

      context 'with varying ratios' do
        let (:counter) { MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 200000, 200001), sample_rate: from_rate) }
        let (:node) { counter.resample(to_rate, mode: resample_mode) }

        [1, 1.001, 2, 2.345, 3, 3.3217, 4, 5, 7651.0 / 400.0, 42.5, 255].each do |r|
          [:ruby_linear, :ruby_zoh, :libsamplerate_linear, :libsamplerate_zoh].each do |m|
            context "when ratio is #{r}" do
              let (:ratio) { r }

              context "when mode is #{m}" do
                let (:resample_mode) { m }
                # libsamplerate has a subsample phase offset that I don't care
                # about, so I'm using a lower number of sigfigs for
                # libsamplerate downsampling.
                let (:tolerance) { resample_mode.to_s.start_with?('ruby') ? 5 : 1 }

                context 'when upsampling' do
                  let (:from_rate) { 100 }
                  let (:to_rate) { 100 * r }
                  let (:output_end) { 200000.0 / ratio }

                  it_behaves_like m.to_s.rpartition('_')[-1]
                end

                context 'when downsampling' do
                  let (:from_rate) { 100 * r }
                  let (:to_rate) { 100 }
                  let (:output_end) { 200000.0 * ratio }

                  it_behaves_like m.to_s.rpartition('_')[-1]
                end
              end
            end
          end
        end
      end

      it 'can upsample a sample counter using :ruby_zoh' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 100, 101), sample_rate: 100)

        d1 = counter.resample(400, mode: :ruby_zoh)

        expect(d1.sample(5)).to eq(Numo::SFloat[0, 0, 0, 0, 1])
        expect(d1.sample(5)).to eq(Numo::SFloat[1, 1, 1, 2, 2])
        expect(d1.sample(3)).to eq(Numo::SFloat[2, 2, 3])
        expect(d1.sample(7)).to eq(Numo::SFloat[3, 3, 3, 4, 4, 4, 4])
      end

      it 'can downsample a sample counter using :ruby_zoh' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 200, 201), sample_rate: 100)

        d1 = counter.resample(25, mode: :ruby_zoh)

        expect(d1.sample(5)).to eq(Numo::SFloat[0, 4, 8, 12, 16])
        expect(d1.sample(5)).to eq(Numo::SFloat[20, 24, 28, 32, 36])
        expect(d1.multi_sample(5, 3)).to eq(Numo::SFloat.linspace(40, 96, 15))
        expect(d1.sample(7)).to eq(Numo::SFloat[100, 104, 108, 112, 116, 120, 124])
      end

      it 'can upsample a sample counter using :ruby_linear' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 100, 101), sample_rate: 100)

        d1 = counter.resample(400, mode: :ruby_linear)

        expect(d1.sample(5)).to eq(Numo::SFloat[0, 0.25, 0.5, 0.75, 1])
        expect(d1.sample(5)).to eq(Numo::SFloat[1.25, 1.5, 1.75, 2, 2.25])
        expect(d1.multi_sample(5, 3)).to eq(Numo::SFloat.linspace(2.5, 6, 15))
        expect(d1.sample(7)).to eq(Numo::SFloat[6.25, 6.5, 6.75, 7, 7.25, 7.5, 7.75])
      end

      it 'can downsample a sample counter using :ruby_linear' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 200, 201), sample_rate: 100)

        d1 = counter.resample(25, mode: :ruby_linear)

        expect(d1.sample(5)).to eq(Numo::SFloat[0, 4, 8, 12, 16])
        expect(d1.sample(5)).to eq(Numo::SFloat[20, 24, 28, 32, 36])
        expect(d1.multi_sample(5, 3)).to eq(Numo::SFloat.linspace(40, 96, 15))
        expect(d1.sample(7)).to eq(Numo::SFloat[100, 104, 108, 112, 116, 120, 124])
      end

      it 'can upsample with a weird ratio regardless of chunk size using :ruby_linear' do
        counter1 = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 3719000, 100001), sample_rate: 100)
        counter2 = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 3719000, 100001), sample_rate: 100)

        d1 = counter1.resample(3719, mode: :ruby_linear)
        d2 = counter2.resample(3719, mode: :ruby_linear)

        data1 = d1.multi_sample(233, 430)[0...100000]
        data2 = d2.sample(100000)

        expect(data1).to all_be_within(5).sigfigs.of_array(data2)
      end
    end

    it 'can resample a more complex upstream graph' do
      node = 150.hz.saw.at(4).filter(500.hz.lowpass).resample(12000).resample(15000)
      ref = 150.hz.saw.at(4).filter(500.hz.lowpass).resample(15000)

      result = node.sample(5000).dup
      expected = ref.sample(5000).dup

      result, expected = select_whole_cycles(result, expected)

      expect(result.length).to be > 4000
      expect(result).to all_be_within(-40.db).of_array(expected)
    end
  end
end
