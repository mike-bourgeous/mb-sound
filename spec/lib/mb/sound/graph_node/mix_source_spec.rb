RSpec.describe(MB::Sound::GraphNode::MixSource) do
  let(:source) { MB::Sound::GraphNode::MixSource.new(channels: 2, sample_rate: 44100) }
  let(:data) { [Numo::SFloat[1, 2, 3], Numo::SFloat[-1, -2, -3]] }

  it 'returns each channel of the latest buffer' do
    source.write(data)
    expect(source.outputs.map { |c| c.sample(3) }).to eq(data)

    source.write([Numo::SFloat[4, 5, 6], Numo::SFloat[7, 8, 9]])
    expect(source.outputs[1].sample(3)).to eq(Numo::SFloat[7, 8, 9])
  end

  it 'returns copies so graphs can modify the result' do
    source.write(data)
    a = source.outputs[0].sample(3)
    a[0] = 10
    expect(data[0]).to eq(Numo::SFloat[1, 2, 3])
    source.write(data)
    expect(source.outputs[0].sample(3)).to eq(data[0])
  end

  # fix-bus-resample-1: a second whole read got the same buffer again, so a
  # resampler's lookahead read the first buffer twice (consumers read a
  # channel through a Tee branch, once per span)
  it 'raises for a read past the written frames' do
    source.write(data)
    source.outputs[0].sample(3)
    expect { source.outputs[0].sample(3) }.to raise_error(ArgumentError, /read 3 frames with 0 written.*reads further ahead/)
  end

  describe '#read_ahead' do
    it 'starts the channels that many frames late, so reads past a write find written frames' do
      source.read_ahead = 2
      source.write(data)
      expect(source.outputs[0].sample(4)).to eq(Numo::SFloat[0, 0, 1, 2])
      expect(source.outputs[1].sample(2)).to eq(Numo::SFloat[0, 0])
      expect(source.outputs[1].sample(1)).to eq(Numo::SFloat[-1])
      source.write([Numo::SFloat[4, 5, 6], Numo::SFloat[7, 8, 9]])
      expect(source.outputs[0].sample(1)).to eq(Numo::SFloat[3])
      expect(source.outputs[0].sample(3)).to eq(Numo::SFloat[4, 5, 6])
      expect(source.outputs[1].sample(5)).to eq(Numo::SFloat[-2, -3, 7, 8, 9])
    end

    it 'raises for a read further ahead than that' do
      source.read_ahead = 2
      source.write(data)
      expect { source.outputs[0].sample(6) }.to raise_error(ArgumentError, /read 6 frames with 5 written \(2 frames of read-ahead\)/)
    end

    it 'grows the buffer for long writes' do
      source.read_ahead = 1
      long = Numo::SFloat.new(5000).seq
      source.write([long, long])
      expect(source.outputs[0].sample(5001)).to eq(Numo::SFloat.zeros(1).concatenate(long))
    end
  end

  it 'works as the start of a graph' do
    chain = source.outputs[0] * 2 + 1
    source.write(data)
    expect(chain.sample(3)).to eq(Numo::SFloat[3, 5, 7])
    expect(chain.graph).to include(source.outputs[0])
    expect(source.outputs[0].original_source).to equal(source)
  end

  it 'raises an error if the chain asks for a different sample count' do
    source.write(data)
    expect { source.outputs[0].sample(4) }.to raise_error(ArgumentError, /read 4 frames with 3 written/)
  end

  # Kez's K10: a Synth reads its lanes in windows (a lane waking inside a
  # buffer), so a bus chain through one read its input in pieces
  # (frames a read leaves wait for the next read since fix-bus-resample-1:
  # a :min_phase resampler reads just what its output covers)
  it 'returns consecutive pieces of the buffer to reads of fewer samples, and keeps what they leave' do
    source.write(data)
    expect(source.outputs[0].sample(1)).to eq(Numo::SFloat[1])
    expect(source.outputs[0].sample(2)).to eq(Numo::SFloat[2, 3])
    expect(source.outputs[1].sample(2)).to eq(Numo::SFloat[-1, -2])
    expect { source.outputs[1].sample(2) }.to raise_error(ArgumentError, /read 2 frames with 1 written/)
    source.write(data)
    expect(source.outputs[1].sample(2)).to eq(Numo::SFloat[-3, -1])
    expect(source.outputs[0].sample(3)).to eq(data[0]) # (whole reads as before)
  end

  it 'drops what a channel nothing read held at the next write' do
    source.write(data)
    source.outputs[0].sample(3)
    source.write([Numo::SFloat[4, 5, 6], Numo::SFloat[7, 8, 9]])
    expect(source.outputs[1].sample(3)).to eq(Numo::SFloat[7, 8, 9])
  end

  it 'raises an error if given the wrong number of channels' do
    expect { source.write([data[0]]) }.to raise_error(ArgumentError, /Expected 2 channels/)
  end

  it 'has a fixed sample rate' do
    expect(source.outputs[0].sample_rate).to eq(44100)
    expect { source.outputs[0].at_rate(44100) }.not_to raise_error
    expect { source.outputs[0].at_rate(48000) }.to raise_error(NotImplementedError, /sample rate/)
  end
end
