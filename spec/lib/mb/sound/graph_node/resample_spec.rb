RSpec.describe(MB::Sound::GraphNode::Resample, :aggregate_failures) do
  it 'can be created' do
    expect { MB::Sound::GraphNode::Resample.new(upstream: 150.hz.triangle, sample_rate: 12345) }.not_to raise_error
  end

  describe '#sample' do
    shared_examples_for 'a working resampler' do |resample_mode|
      # Compensate for lag
      def skip_leading_and_truncate(resampled, reference)
        resampled = MB::M.skip_leading(resampled, 0)
        reference = MB::M.skip_leading(reference, 0)
        min_length = [resampled.length, reference.length].min
        resampled = resampled[0...min_length]
        reference = reference[0...min_length]
        return resampled, reference
      end

      context 'when upsampling' do
        it 'can upsample with a reasonable noise floor' do
          resampled = 453.hz.at(1).at_rate(11376).resample(96000, mode: resample_mode).sample(24000)
          reference = 453.hz.at(1).at_rate(96000).sample(24000)
          resampled, reference = skip_leading_and_truncate(resampled, reference)

          delta = resampled - reference

          # TODO: get max lower by aligning on zero crossings after a few wavelengths
          expect(delta.abs.max).to be_between(-250.db, 0.11)
        end

        it 'does not matter what the upsampling chunk size is' do
          large_window = 47.hz.at(1).forever.at_rate(400).resample(17521, mode: resample_mode).sample(27000)
          small_window = 47.hz.at(1).forever.at_rate(400).resample(17521, mode: resample_mode).multi_sample(216, 125)
          large_window, small_window = skip_leading_and_truncate(large_window, small_window)
          large_window = large_window[0...16000]
          small_window = small_window[0...16000]

          delta = large_window - small_window

          expect(delta.abs.max).to eq(0)
        end

        pending 'upsamples end of stream on buffer boundary'
        pending 'upsamples end of stream within a buffer'
        pending 'upsamples correctly when chunk sizes change'
      end

      context 'when downsampling' do
        it 'can downsample with a reasonable noise floor' do
          resampled = 157.hz.at(1).at_rate(96000).resample(5700, mode: resample_mode).sample(9600)
          reference = 157.hz.at(1).at_rate(5700).sample(9600)
          resampled, reference = skip_leading_and_truncate(resampled, reference)

          delta = resampled - reference

          # TODO: get max lower by aligning on zero crossings after a few wavelengths
          expect(delta.abs.max).to be_between(-250.db, 0.11)
        end

        it 'does not matter what the downsampling chunk size is' do
          large_window = 43.hz.at(1).forever.at_rate(17521).resample(400, mode: resample_mode).sample(27000)
          small_window = 43.hz.at(1).forever.at_rate(17521).resample(400, mode: resample_mode).multi_sample(216, 125)
          large_window, small_window = skip_leading_and_truncate(large_window, small_window)
          large_window = large_window[0...16000]
          small_window = small_window[0...16000]

          delta = large_window - small_window

          expect(delta.abs.max).to eq(0)
        end

        pending 'downsamples end of stream on buffer boundary'
        pending 'downsamples end of stream within a buffer'
        pending 'downsamples correctly when chunk sizes change'
      end
    end

    MB::Sound::GraphNode::Resample::MODES.each do |resample_mode|
      context "when resampling mode is #{resample_mode.inspect}" do
        it_behaves_like 'a working resampler', resample_mode
      end
    end

    context 'with the default mode' do
      it_behaves_like 'a working resampler', MB::Sound::GraphNode::Resample::DEFAULT_MODE
    end

    it 'gives the same results for different chunk sizes (from plot_resampler_window_delta.rb)' do
      d1 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: :ruby_zoh).sample(27000), 0)[0...16000]
      d2 = MB::M.skip_leading(40.hz.at(1).at_rate(400).resample(16000, mode: :ruby_zoh).multi_sample(216, 125), 0)[0...16000]
      delta = d2.not_inplace! - d1.not_inplace!
      expect(delta.abs.max).to eq(0)
    end

    context 'using a sample counter to verify time linearity' do
      shared_examples_for 'zoh or linear' do
        it 'has the expected output when sampling all at once' do
          expect(node.sample(60)).to all_be_within(5).sigfigs.of_array(expected[0...60])
        end

        it 'has the expected output when sampling in random chunks' do
          expect(node.multi_sample(7, 3)).to all_be_within(5).sigfigs.of_array(expected[0...21])
          expect(node.sample(30)).to all_be_within(5).sigfigs.of_array(expected[21...51])
          expect(node.sample(3)).to all_be_within(5).sigfigs.of_array(expected[51...54])
        end

        it 'has the expected output when sampling in consistent chunks' do
          expect(node.multi_sample(11, 5)).to all_be_within(5).sigfigs.of_array(expected[0...55])
        end
      end

      shared_examples_for 'zoh' do
        let (:expected) { Numo::Int32.linspace(0, output_end, 50001) }
        it_behaves_like 'zoh or linear'
      end

      shared_examples_for 'linear' do
        let (:expected) { Numo::SFloat.linspace(0, output_end, 50001) }
        it_behaves_like 'zoh or linear'
      end

      context 'with varying ratios' do
        let (:counter) { MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 50000, 50001), sample_rate: from_rate) }
        let (:node) { counter.resample(to_rate, mode: resample_mode) }

        [1, 2, 2.345, 3, 3.3217, 4, 5].each do |r|
          [:ruby_linear, :ruby_zoh, :libsamplerate_linear, :libsamplerate_zoh].each do |m|
            context "when ratio is #{r}" do
              let (:ratio) { r }

              context "when mode is #{m}" do
                let(:resample_mode) { m }

                context 'when upsampling' do
                  let (:from_rate) { 100 }
                  let (:to_rate) { 100 * r }
                  let (:output_end) { 50000.0 / ratio }

                  it_behaves_like m.to_s.rpartition('_')[-1]
                end

                context 'when downsampling' do
                  let (:from_rate) { 100 * r }
                  let (:to_rate) { 100 }
                  let (:output_end) { 50000.0 * ratio }

                  it_behaves_like m.to_s.rpartition('_')[-1]
                end
              end
            end
          end
        end
      end

      it 'can upsample a zoh counter using :ruby_zoh' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 100, 101), sample_rate: 100)

        d1 = counter.resample(400, mode: :ruby_zoh)

        expect(d1.sample(5).real).to eq(Numo::SFloat[0, 0, 0, 0, 1]) # XXX real
        expect(d1.sample(5).real).to eq(Numo::SFloat[1, 1, 1, 2, 2]) # XXX real)
        expect(d1.sample(3).real).to eq(Numo::SFloat[2, 2, 3]) # XXX real
        expect(d1.sample(7).real).to eq(Numo::SFloat[3, 3, 3, 4, 4, 4, 4]) # XXX real
      end

      it 'can downsample a zoh counter using :ruby_zoh' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 200, 201), sample_rate: 100)

        d1 = counter.resample(25, mode: :ruby_zoh)

        expect(d1.sample(5).real).to eq(Numo::SFloat[0, 4, 8, 12, 16]) # XXX real
        expect(d1.sample(5).real).to eq(Numo::SFloat[20, 24, 28, 32, 36]) # XXX real)
        expect(d1.multi_sample(5, 3).real).to eq(Numo::SFloat.linspace(40, 96, 15))
        expect(d1.sample(7).real).to eq(Numo::SFloat[100, 104, 108, 112, 116, 120, 124]) # XXX real
      end

      it 'can upsample a linear counter using :ruby_linear' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 100, 101), sample_rate: 100)

        d1 = counter.resample(400, mode: :ruby_linear)

        expect(d1.sample(5).real).to eq(Numo::SFloat[0, 0.25, 0.5, 0.75, 1]) # XXX real
        expect(d1.sample(5).real).to eq(Numo::SFloat[1.25, 1.5, 1.75, 2, 2.25]) # XXX real)
        expect(d1.multi_sample(5, 3).real).to eq(Numo::SFloat.linspace(2.5, 6, 15))
        expect(d1.sample(7).real).to eq(Numo::SFloat[6.25, 6.5, 6.75, 7, 7.25, 7.5, 7.75]) # XXX real
      end

      it 'can downsample a linear counter using :ruby_linear' do
        counter = MB::Sound::ArrayInput.new(data: Numo::SFloat.linspace(0, 200, 201), sample_rate: 100)

        d1 = counter.resample(25, mode: :ruby_linear)

        expect(d1.sample(5).real).to eq(Numo::SFloat[0, 4, 8, 12, 16]) # XXX real
        expect(d1.sample(5).real).to eq(Numo::SFloat[20, 24, 28, 32, 36]) # XXX real)
        expect(d1.multi_sample(5, 3).real).to eq(Numo::SFloat.linspace(40, 96, 15))
        expect(d1.sample(7).real).to eq(Numo::SFloat[100, 104, 108, 112, 116, 120, 124]) # XXX real
      end
    end

    pending 'with a more complex upstream graph'
  end
end
