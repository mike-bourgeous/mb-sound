RSpec.describe(MB::Sound::Wavetable::Tools, aggregate_failures: true) do
  let (:one_table) {
    Numo::SFloat[[5, -3, 3, -1, 2]]
  }

  let (:table) {
    Numo::SFloat[
      [1, 2, 3, 4, 5],
      [5, -3, 3, -1, 2],
      [-1, 1, 0, 3, -4],
    ]
  }

  describe '.load_frames' do
    it 'can load an existing wavetable' do
      data = MB::Sound::Wavetable.load_frames('spec/test_data/short_wavetable.flac')
      expect(data).to all_be_within(1e-6).of_array(table/5)
    end
  end

  describe '.save_frames' do
    it 'can write a wavetable to disk' do
      data = Numo::SFloat[
        [0.5, -0.5, 0],
        [0.1, 0.2, -0.3],
        [-0.75, 0.25, 0.75],
      ]

      name = tmp_path('wavetable_save.flac')

      MB::Sound::Wavetable.save_frames(name, data)

      metadata = {}
      result = MB::Sound.read(name, metadata_out: metadata)[0]
      expect(result).to all_be_within(1e-6).of_array(Numo::SFloat[0.5, -0.5, 0, 0.1, 0.2, -0.3, -0.75, 0.25, 0.75])
      expect(metadata[:mb_sound_wavetable_period]&.to_i).to eq(3)
    end

    it 'can write a single-row wavetable to disk' do
      name = tmp_path('single_wavetable_save.flac')

      MB::Sound::Wavetable.save_frames(name, one_table / 5)

      metadata = {}
      result = MB::Sound.read(name, metadata_out: metadata)[0]
      expect(result).to all_be_within(1e-6).of_array(one_table.reshape(5) / 5)
      expect(metadata[:mb_sound_wavetable_period]&.to_i).to eq(5)
    end
  end

  describe '.slice_frames' do
    it 'slices a sound into cycles of its fundamental' do
      data = MB::Sound.read('sounds/piano_120hz_b2.flac')[0]
      frames = MB::Sound::Wavetable.slice_frames(data, slices: 4, metadata_out: nil)
      expect(frames.shape).to eq([4, 400])
      expect(frames.abs.max).to be_within(1e-5).of(1)
    end
  end

  describe '.generate' do
    let (:fm_table) { MB::Sound::Wavetable.generate { |v, t| t.fm(t.frequency * (1 + v)) } }

    it 'defaults to 10x2048' do
      expect(fm_table.shape).to eq([10, 2048])
      expect(fm_table.min.round(6)).to eq(-1)
      expect(fm_table.max.round(6)).to eq(1)
    end

    it 'can generate different sizes' do
      expect(MB::Sound::Wavetable.generate(steps: 71, length: 147) { |_v, t| t }.shape).to eq([71, 147])
    end

    it 'can assemble NArrays' do
      table = MB::Sound::Wavetable.generate(normalize: false, fade_edges: false) { |v, _t| Numo::SFloat.linspace(-v, v, 2048) }
      expect(table[-1, nil].min.round(6)).to eq(-1)
      expect(table[-1, nil].max.round(6)).to eq(1)
      expect(table[1, nil].min.round(6)).to eq(-MB::M.smoothstep(1.0 / 9.0).round(6))
      expect(table[1, nil].max.round(6)).to eq(MB::M.smoothstep(1.0 / 9.0).round(6))
    end

    pending ':curve'

    pending 'post-processing parameters'
  end

  describe '.blur' do
    it 'blends adjacent rows' do
      blurred = MB::Sound::Wavetable.blur(table, 1)
      expect(blurred).to all_be_within(1e-6).of_array(Numo::SFloat[
        *([[5.0 / 3.0, 0, 2, 2, 1]] * 3)
      ])
    end

    it 'can blend partially' do
      blurred = MB::Sound::Wavetable.blur(table, 0.5)
      expect(blurred).to all_be_within(1e-6).of_array(Numo::SFloat[
        [1.5, 0.5, 2.25, 2.5, 2],
        [2.5, -0.75, 2.25, 1.25, 1.25],
        [1, 0.25, 1.5, 2.25, -0.25]
      ])
    end

    it 'can subtract instead of adding' do
      blurred = MB::Sound::Wavetable.blur(table, -1)
      expect(blurred).to all_be_within(1e-5).of_array(Numo::SFloat[
        [-1, 1.33333, 0, 0.666667, 2.33333],
        [1.66667, -2, 0, -2.66667, 0.333333],
        [-2.33333, 0.666667, -2, 0, -3.66667]
      ])
    end

    pending 'works with steps set to 1'
  end

  describe '.normalize' do
    it 'removes DC from and normalizes a wavetable to +/-1 by default' do
      expect(MB::Sound::Wavetable.normalize(Numo::SFloat[[1, 0], [1, 2]])).to all_be_within(1e-6).of_array(Numo::SFloat[[1, -1], [-1, 1]])
    end

    it 'can normalize to a different max value' do
      expect(MB::Sound::Wavetable.normalize(Numo::SFloat[[1, 0], [1, 2]], 0.5)).to all_be_within(1e-6).of_array(Numo::SFloat[[0.5, -0.5], [-0.5, 0.5]])
    end
  end

  describe '.center' do
    let (:zc_table) {
      Numo::SFloat[
        [2, 3, -1, -2, -3, 1],
        [0, 1, 2, 3, 4, -1],
      ]
    }

    let (:zc_expected) {
      Numo::SFloat[
        [-1, -2, -3, 1, 2, 3],
        [3, 4, -1, 0, 1, 2],
      ]
    }

    let (:zc_odd) {
      Numo::SFloat[
        [2, 3, -1, -2, -3, 1, 1],
        [0, 1, 2, 3, 4, -1, -2],
      ]
    }

    let (:odd_expected) {
      Numo::SFloat[
        [-1, -2, -3, 1, 1, 2, 3],
        [4, -1, -2, 0, 1, 2, 3],
      ]
    }

    it 'centers a wavetable that has zero crossings' do
      expect(MB::Sound::Wavetable.center(zc_table)).to eq(zc_expected)
    end

    it 'works with odd lengths' do
      expect(MB::Sound::Wavetable.center(zc_odd)).to eq(odd_expected)
    end

    it 'raises an error if there is no zero crossing' do
      expect { MB::Sound::Wavetable.center(table) }.to raise_error(/crossing.*row 0/)
      expect { MB::Sound::Wavetable.center(zc_table + 2) }.to raise_error(/crossing.*row 1/)
    end

    it 'does not modify the table if it is not in place' do
      expect { MB::Sound::Wavetable.center(zc_table) }.not_to change { zc_table }
    end

    it 'can work in place' do
      zc_odd.inplace!
      expect(MB::Sound::Wavetable.center(zc_odd)).to eql(zc_odd)

      expect { MB::Sound::Wavetable.center(zc_table) }.not_to change { zc_table.to_a }
      zc_table.inplace!
      expect { MB::Sound::Wavetable.center(zc_table) }.to change { zc_table.to_a }
    end

    pending 'works with a single-row wavetable'
  end
end
