RSpec.describe(MB::Sound::MIDI::ControlSpec) do
  describe 'CCs' do
    it 'maps raw values linearly, around a center, or as a switch' do
      expect(described_class.new(number: 1).value(127)).to eq(1)
      expect(described_class.new(number: 1, range: 0.0..2.0, center: 1.0).value(64)).to eq(1)
      expect(described_class.new(number: 64, curve: :switch).value(64)).to eq(1)
      expect(described_class.new(number: 64, curve: :switch).value(63)).to eq(0)
    end

    it 'has a number, a status of 176, and a raw maximum of 127' do
      s = described_class.new(number: 7, name: 'Volume', default: 100)
      expect(s).to have_attributes(type: :cc, cc?: true, status: 176, raw_max: 127, key: [176, 7])
      expect(s.to_s).to eq('CC 7 Volume (0.0..1.0, default 100)')
    end

    it 'requires a number and a raw default within 0..127' do
      expect { described_class.new }.to raise_error(ArgumentError, /number/)
      expect { described_class.new(number: 1, default: 128) }.to raise_error(ArgumentError, /Default/)
      expect { described_class.new(type: :knob, number: 1) }.to raise_error(ArgumentError, /type/)
    end
  end

  describe '.bend' do
    let(:spec) { described_class.bend }

    it 'maps raw 0..16383 to -1..1 like MIDI::Event.bend_value, centered at 8192' do
      expect(spec).to have_attributes(type: :bend, number: nil, name: 'Pitch Bend', default: 8192, raw_max: 16383, status: 224)
      [0, 1, 4000, 8191, 8192, 8193, 12000, 16383].each do |raw|
        expect(spec.value(raw)).to be_within(1e-12).of(MB::Sound::MIDI::Event.bend_value(raw))
      end
      expect(spec.default_value).to eq(0)
    end

    it 'takes a range, e.g. semitones' do
      st = described_class.bend(range: -12.0..12.0)
      expect(st.value(0)).to eq(-12)
      expect(st.value(16383)).to eq(12)
      expect(st.default_value).to eq(0)
      expect(st.to_s).to eq('Pitch Bend (-12.0..12.0, default 8192)')
    end

    it 'has no number and takes 14-bit defaults' do
      expect { described_class.new(type: :bend, number: 3) }.to raise_error(ArgumentError, /numbers/)
      expect(described_class.new(type: :bend, default: 16383).default).to eq(16383)
      expect { described_class.new(type: :bend, default: 16384) }.to raise_error(ArgumentError, /Default/)
    end
  end

  describe '.pressure' do
    it 'maps raw 0..127 to 0..1, status 208' do
      spec = described_class.pressure
      expect(spec).to have_attributes(type: :pressure, number: nil, name: 'Aftertouch', default: 0, raw_max: 127, status: 208, key: [208, 0])
      expect(spec.value(127)).to eq(1)
    end
  end
end
