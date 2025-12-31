RSpec.describe(MB::Sound::Wavetable, aggregate_failures: true) do
  let(:table) {
    Numo::SFloat[
      [1, 2, 3, 4, 5],
      [5, -3, 3, -1, 2],
      [-1, 1, 0, 3, -4],
    ]
  }

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

  pending '.make_wavetable'

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
  end

  describe '.normailze' do
    it 'removes DC from and normalizes a wavetable to +/-1 by default' do
      expect(MB::Sound::Wavetable.normalize(Numo::SFloat[[1, 0], [1, 2]])).to all_be_within(1e-6).of_array(Numo::SFloat[[1, -1], [-1, 1]])
    end

    it 'can normalize to a different max value' do
      expect(MB::Sound::Wavetable.normalize(Numo::SFloat[[1, 0], [1, 2]], 0.5)).to all_be_within(1e-6).of_array(Numo::SFloat[[0.5, -0.5], [-0.5, 0.5]])
    end
  end

  context 'array lookup' do
    shared_examples_for 'wavetable lookup' do |m|
      let(:number) { Numo::SFloat[0, 1.0 / 3.0, 2.0 / 3.0, -2.0 / 3.0, 1.0 / 6.0] }
      let(:phase) { Numo::SFloat[0, 0.4, 0.6, 1.2, 0.1] }

      let(:oob_number) { Numo::SFloat[0, 1.0 / 3.0, 2.0 / 3.0, -2.0 / 3.0, 1.0 / 6.0, 5.0 / 3.0] }
      let(:oob_phase) { Numo::SFloat[0.1, 0.6, -0.1, 0.9, 1.05, -0.25] }

      it 'can perform lookups based on arrays with linear interpolation' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: number, phase: phase, lookup: :linear, wrap: :wrap)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1, 3, 3, -3, 1.25])
      end

      it 'can perform lookups based on arrays with cubic interpolation' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: number, phase: phase, lookup: :cubic, wrap: :wrap)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1, 3, 3, -3, 1])
      end

      it 'can bounce linear oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :linear, wrap: :bounce)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.5, -1, 0, 0.5, 1.875, 0.75])
      end

      it 'can bounce cubic oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :cubic, wrap: :bounce)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.375, -1, -0.0625, 0.4375, 1.74609375, 0.8671875])
      end

      it 'can clamp linear oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :linear, wrap: :clamp)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.5, -1, -1, 2, 3.5, -1])
      end

      it 'can clamp cubic oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :cubic, wrap: :clamp)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.4375, -1, -1.125, 2.1875, 3.5, -1])
      end

      it 'can zero linear oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :linear, wrap: :zero)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.5, -1, -0.5, 1, 0, 0])
      end

      it 'can zero cubic oob' do
        result = MB::Sound::Wavetable.send(m, wavetable: table, number: oob_number, phase: oob_phase, lookup: :cubic, wrap: :zero)
        expect(result).to all_be_within(1e-5).of_array(Numo::SFloat[1.5, -1, -0.625, 1.1875, -0.24609375, 0.0703125])
      end
    end

    describe '.wavetable_lookup' do
      it_behaves_like 'wavetable lookup', :wavetable_lookup
    end

    describe '.wavetable_lookup_c' do
      it_behaves_like 'wavetable lookup', :wavetable_lookup_c
    end

    describe '.wavetable_lookup_ruby' do
      it_behaves_like 'wavetable lookup', :wavetable_lookup_ruby
    end
  end

  context 'single element lookup' do
    shared_examples_for 'exact lookup' do |m|
      it 'can retrieve exact rows in the wavetable' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0, wrap: :wrap).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 0, wrap: :wrap).round(6)).to eq(-1)
      end

      it 'can retrieve exact columns in the wavetable' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.2, wrap: :wrap).round(6)).to eq(2)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.4, wrap: :wrap).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.6, wrap: :wrap).round(6)).to eq(4)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.8, wrap: :wrap).round(6)).to eq(5)
      end

      it 'wraps around rows' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1, phase: 0, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2, phase: 0, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 4.0 / 3.0, phase: 0, wrap: :wrap).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: -1.0 / 3.0, phase: 0, wrap: :wrap).round(6)).to eq(-1)
      end

      it 'can interpolate between rows' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 6.0, phase: 0.8, wrap: :wrap).round(6)).to eq(3.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 3.0 / 6.0, phase: 0.6, wrap: :wrap).round(6)).to eq(1.0)
      end

      it 'can blend straight line columns regardless of interpolation type' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.3, wrap: :wrap).round(6)).to eq(2.5)
      end

      it 'wraps around columns with :wrap' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 2, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -1, wrap: :wrap).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.2, wrap: :wrap).round(6)).to eq(2)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.2, wrap: :wrap).round(6)).to eq(5)
      end

      it 'can reflect exactly with :bounce' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1, wrap: :bounce).round(6)).to eq(4)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 2, wrap: :bounce).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -1, wrap: :bounce).round(6)).to eq(4)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.2, wrap: :bounce).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.2, wrap: :bounce).round(6)).to eq(-3)
      end

      it 'can clamp with :clamp' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.41, wrap: :clamp).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.4, wrap: :clamp).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.2, wrap: :clamp).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1, wrap: :clamp).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.2, wrap: :clamp).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.21, wrap: :clamp).round(6)).to eq(5)
      end

      it 'can set to zero with :zero' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.41, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.4, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.2, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.2, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.21, wrap: :zero).round(6)).to eq(0)
      end
    end

    shared_examples_for 'linear lookup' do |m|
      it 'can interpolate between columns' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.1, wrap: :wrap).round(6)).to eq(1.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.1, wrap: :wrap).round(6)).to eq(1.0)
      end

      it 'can interpolate between rows and columns' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 6.0, phase: 0.7, wrap: :wrap).round(6)).to eq(2.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 3.0 / 6.0, phase: 0.3, wrap: :wrap).round(6)).to eq(0.25)
      end

      it 'can wrap between columns with :wrap' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.3, wrap: :wrap).round(6)).to eq(4.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.1, wrap: :wrap).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.9, wrap: :wrap).round(6)).to eq(3.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 1.1, wrap: :wrap).round(6)).to eq(1.0)
      end

      it 'can reflect between columns with :bounce' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.3, wrap: :bounce).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.1, wrap: :bounce).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.9, wrap: :bounce).round(6)).to eq(0.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 1.1, wrap: :bounce).round(6)).to eq(1)
      end

      it 'can interpolate to zero with :zero' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.3, wrap: :zero).round(6)).to eq(0)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.1, wrap: :zero).round(6)).to eq(2.5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 0.9, wrap: :zero).round(6)).to eq(-2)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 1.1, wrap: :zero).round(6)).to eq(0)
      end

      it 'can clamp between columns with :clamp' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.1, wrap: :clamp).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.05, wrap: :clamp).round(6)).to eq(1)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.85, wrap: :clamp).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.9, wrap: :clamp).round(6)).to eq(5)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.1, wrap: :clamp).round(6)).to eq(5)
      end
    end

    shared_examples_for 'cubic lookup' do |m|
      # Values computed manually using previously tested cubic interpolation function
      it 'can interpolate between columns' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.1, wrap: :wrap).round(6)).to eq(1.1875)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.1, wrap: :wrap).round(6)).to eq(0.8125)
      end

      it 'can interpolate between rows and columns' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 6.0, phase: 0.7, wrap: :wrap).round(6)).to eq(2.4375)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 3.0 / 6.0, phase: 0.3, wrap: :wrap).round(6)).to eq(0.09375)
      end

      it 'can wrap between columns with :wrap' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.3, wrap: :wrap).round(6)).to eq(4.8125)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.1, wrap: :wrap).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.9, wrap: :wrap).round(6)).to eq(4.1875)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 1.1, wrap: :wrap).round(6)).to eq(0.8125)
      end

      it 'can reflect between columns with :bounce' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.3, wrap: :bounce).round(6)).to eq(-0.25)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.1, wrap: :bounce).round(6)).to eq(1.125)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.9, wrap: :bounce).round(6)).to eq(0.4375)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 1.1, wrap: :bounce).round(6)).to eq(1.1875)
      end

      it 'can interpolate to zero with :zero' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.3, wrap: :zero).round(6)).to eq(-0.3125)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: -0.1, wrap: :zero).round(6)).to eq(3)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.1, wrap: :zero).round(6)).to eq(0.9375)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 0.7, wrap: :zero).round(6)).to eq(-0.5625)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 0.9, wrap: :zero).round(6)).to eq(-2.4375)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 1.05, wrap: :zero).round(6)).to eq(0.28125)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 2.0 / 3.0, phase: 1.1, wrap: :zero).round(6)).to eq(0.25)
      end

      it 'can clamp between columns with :clamp' do
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.1, wrap: :clamp).round(6)).to eq(0.9375)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: -0.05, wrap: :clamp).round(6)).to eq(0.9296875.round(6))
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 1.0 / 3.0, phase: 0.1, wrap: :clamp).round(6)).to eq(0.625)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.7, wrap: :clamp).round(6)).to eq(4.5625)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.85, wrap: :clamp).round(6)).to eq(5.0703125.round(6))
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 0.9, wrap: :clamp).round(6)).to eq(5.0625)
        expect(MB::Sound::Wavetable.send(m, wavetable: table, number: 0, phase: 1.1, wrap: :clamp).round(6)).to eq(5)
      end
    end

    describe '.outer_linear' do
      it_behaves_like 'exact lookup', :outer_linear
      it_behaves_like 'linear lookup', :outer_linear
    end

    describe '.outer_linear_c' do
      it_behaves_like 'exact lookup', :outer_linear_c
      it_behaves_like 'linear lookup', :outer_linear_c
    end

    describe '.outer_linear_ruby' do
      it_behaves_like 'exact lookup', :outer_linear_ruby
      it_behaves_like 'linear lookup', :outer_linear_ruby
    end

    describe '.outer_cubic' do
      it_behaves_like 'exact lookup', :outer_cubic
      it_behaves_like 'cubic lookup', :outer_cubic
    end

    describe '.outer_cubic_c' do
      it_behaves_like 'exact lookup', :outer_cubic_c
      it_behaves_like 'cubic lookup', :outer_cubic_c
    end

    describe '.outer_cubic_ruby' do
      it_behaves_like 'exact lookup', :outer_cubic_ruby
      it_behaves_like 'cubic lookup', :outer_cubic_ruby
    end
  end
end
