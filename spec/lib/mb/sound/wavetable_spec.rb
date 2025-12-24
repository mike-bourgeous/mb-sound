RSpec.describe(MB::Sound::Wavetable, aggregate_failures: true) do
  let(:table) {
    Numo::SFloat[
      [1, 2, 3, 4, 5],
      [5, -3, 3, -1, 2],
      [-1, 1, 0, 3, -4],
    ]
  }

  before(:all) do
    # FIXME: control mode with parameters
    $wavetable_mode = :linear
  end

  describe '.load_wavetable' do
    it 'can load an existing wavetable' do
      data = MB::Sound::Wavetable.load_wavetable('spec/test_data/short_wavetable.flac')
      expect(data).to all_be_within(1e-6).of_array(table/5)
    end
  end

  describe '.save_wavetable' do
    it 'can write a wavetable to disk' do
      data = Numo::SFloat[
        [0.5, -0.5, 0],
        [0.1, 0.2, -0.3],
        [-0.75, 0.25, 0.75],
      ]

      name = 'tmp/wavetable_save.flac'

      FileUtils.mkdir_p('tmp/')
      File.unlink(name) rescue nil

      MB::Sound::Wavetable.save_wavetable(name, data)

      metadata = {}
      result = MB::Sound.read(name, metadata_out: metadata)[0]
      expect(result).to all_be_within(1e-6).of_array(Numo::SFloat[0.5, -0.5, 0, 0.1, 0.2, -0.3, -0.75, 0.25, 0.75])
      expect(metadata[:mb_sound_wavetable_period]&.to_i).to eq(3)
    end
  end

  context 'wavetable lookup' do
    [:wavetable_lookup, :wavetable_lookup_c, :wavetable_lookup_ruby].each do |m|
      describe "##{m}" do
        it 'can perform lookups based on arrays' do
          number = Numo::SFloat[0, 1.0 / 3.0, 2.0 / 3.0, -2.0 / 3.0, 1.0 / 6.0]
          phase = Numo::SFloat[0, 0.4, 0.6, 1.2, 0.1]

          # FIXME: cubic interpolation changes last value
          result = MB::Sound::Wavetable.send(m, wavetable: table, number: number, phase: phase)
          expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1, 3, 3, -3, 1.25])
        end
      end
    end
  end

  context 'linear interpolated lookup' do
    [:outer_linear, :outer_linear_c, :outer_linear_ruby].each do |m|
      describe "##{m}" do
        it 'can retrieve exact rows in the wavetable' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0).round(6)).to eq(5)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 0).round(6)).to eq(-1)
        end

        it 'can retrieve exact columns in the wavetable' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.2).round(6)).to eq(2)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.4).round(6)).to eq(3)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.6).round(6)).to eq(4)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.8).round(6)).to eq(5)
        end

        it 'wraps around rows' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1, phase: 0).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2, phase: 0).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 4.0 / 3.0, phase: 0).round(6)).to eq(5)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: -1.0 / 3.0, phase: 0).round(6)).to eq(-1)
        end

        it 'wraps around columns' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1).round(6).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 2).round(6).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -1).round(6).round(6)).to eq(1)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.2).round(6).round(6)).to eq(2)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.2).round(6).round(6)).to eq(5)
        end

        it 'can interpolate between rows' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 6.0, phase: 0.8).round(6)).to eq(3.5)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 3.0 / 6.0, phase: 0.6).round(6)).to eq(1.0)
        end

        it 'can interpolate between columns' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.1).round(6)).to eq(1.5)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.1).round(6)).to eq(1.0)
        end

        it 'can interpolate between rows and columns' do
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 6.0, phase: 0.7).round(6)).to eq(2.5)
          expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 3.0 / 6.0, phase: 0.3).round(6)).to eq(0.25)
        end
      end
    end
  end
end
