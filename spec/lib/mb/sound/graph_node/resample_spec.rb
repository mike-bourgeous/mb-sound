RSpec.describe(MB::Sound::GraphNode::Resample) do
  it 'can be created' do
    expect { MB::Sound::GraphNode::Resample.new(upstream: 150.hz.triangle, sample_rate: 12345) }.not_to raise_error
  end

  describe '#sample' do
    shared_examples_for 'a working resampler' do |resample_mode|
      it 'can upsample' do
        resampled = 150.hz.at(1).at_rate(12000).resample(96000, mode: resample_mode).sample(24000)
        reference = 150.hz.at(1).at_rate(96000).sample(24000)

        delta = resampled - reference

        expect(delta.abs.max).to be < 0.1
      end

      it 'can downsample' do
        resampled = 150.hz.at(1).at_rate(96000).resample(9600, mode: resample_mode).sample(9600)
        reference = 150.hz.at(1).at_rate(9600).sample(9600)

        delta = resampled - reference

        expect(delta.abs.max).to be < 0.1
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
  end

  pending 'with an upstream graph'
end
