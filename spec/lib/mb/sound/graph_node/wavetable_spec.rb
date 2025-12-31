RSpec.describe(MB::Sound::GraphNode::Wavetable) do
  let(:data) { Numo::SFloat[[1, -1, 1, 1, -1, -1], [0, 1, -1, 1, 0, -1]] }

  before(:all) do
    # FIXME: control mode with parameters
    $wavetable_mode = :linear
  end

  describe '#initialize' do
    it 'can create a wavetable node from an NArray' do
      expect(120.hz.ramp.wavetable(wavetable: data, number: 0.constant)).to be_a(MB::Sound::GraphNode::Wavetable)
    end

    it 'can create a wavetable node from a saved wavetable' do
      wt = 120.hz.ramp.wavetable(wavetable: 'spec/test_data/short_wavetable.flac', number: 0.constant)
      expect(wt).to be_a(MB::Sound::GraphNode::Wavetable)
      expect(wt.table).to be_a(Numo::NArray)
      expect(wt.table.shape).to eq([3, 5])
    end

    it 'can create a wavetable node from an existing sound file by name' do
      wt = 120.hz.ramp.wavetable(wavetable: 'sounds/sine/sine_100_1s_mono.flac', number: 0.constant)
      expect(wt).to be_a(MB::Sound::GraphNode::Wavetable)
      expect(wt.table).to be_a(Numo::NArray)
      expect(wt.table.shape).to eq([10, 480])
    end

    it 'can create a wavetable node from an existing sound by Hash' do
      wt = 120.hz.ramp.wavetable(wavetable: { wavetable: 'sounds/sine/sine_100_1s_mono.flac', slices: 3, ratio: 0.5 }, number: 0.constant)
      expect(wt).to be_a(MB::Sound::GraphNode::Wavetable)
      expect(wt.table).to be_a(Numo::NArray)
      expect(wt.table.shape).to eq([3, 240])
    end
  end

  describe '#sample' do
    it 'treats the upstream data as the phase source' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(0, 2, 13)])
      number = 0.constant
      expect(phase.wavetable(wavetable: data, number: number).sample(12)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, -1, 1, 1, -1, -1, 1, -1, 1, 1, -1, -1]
      )
    end

    it 'changes wave number based on the number source' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0, 1.0 / 6.0, 1.0 / 6.0]], repeat: true)
      number = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0.5, 1, 1.5]], repeat: true)
      expect(phase.wavetable(wavetable: data, number: number).sample(8)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, 0, -1, 1, 1, 0, -1, 1]
      )
    end

    it 'changes wave number based on the number source using linspace' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0, 1.0 / 6.0, 1.0 / 6.0]], repeat: true)
      number = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(0, 4, 9)])
      expect(phase.wavetable(wavetable: data, number: number).sample(8)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, 0, -1, 1, 1, 0, -1, 1]
      )
    end
  end

  describe '#wrap=' do
    let(:phase) { MB::Sound::ArrayInput.new(data: [ Numo::SFloat[0, 1.0 / 4.0, 1, 5.0 / 4.0, -1.0 / 4.0] ]) }
    let(:table) { Numo::SFloat[[1, -2, 3, -4]] }

    it 'can change the wrapping mode to :wrap' do
      expect(phase.wavetable(wavetable: table, number: 0, wrap: :wrap).sample(phase.length)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, -2, 1, -2, -4]
      )
    end

    it 'can change the wrapping mode to :bounce' do
      expect(phase.wavetable(wavetable: table, number: 0, wrap: :bounce).sample(phase.length)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, -2, 3, -2, -2]
      )
    end

    it 'can change the wrapping mode to :clamp' do
      expect(phase.wavetable(wavetable: table, number: 0, wrap: :clamp).sample(phase.length)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, -2, -4, -4, 1]
      )
    end

    it 'can change the wrapping mode to :zero' do
      expect(phase.wavetable(wavetable: table, number: 0, wrap: :zero).sample(phase.length)).to all_be_within(1e-6).of_array(
        Numo::SFloat[1, -2, 0, 0, 0]
      )
    end
  end
end
