RSpec.describe(MB::Sound::Filter::FilterChain) do
  let (:chain) {
    MB::Sound::Filter::FilterChain.new(
      MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 1000, shelf_slope: 1.0, db_gain: -6.0),
      MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 2000, shelf_slope: 1.0, db_gain: -3.0),
      MB::Sound::Filter::FIR.new({100 => -2.db, 20000 => 0.db})
    )
  }

  let (:biquad) {
    MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 4800)
  }

  [:chain, :biquad].each do |f|
    context "with #{f}" do
      let(:filter) { send(f) }

      describe '#reset' do
        [0, 0.5, -0.75].each do |v|
          it "returns the steady state output for #{v}" do
            expect(filter.reset(v).round(6)).to eq((v * filter.response(0).real).round(6))
          end

          it "can reset to #{v}" do
            noise = Numo::SFloat.zeros(20000).rand(-1, 1)
            filter.process(noise)
            filter.reset(v)
            input = Numo::SFloat.zeros(500).fill(v)
            output = input * filter.response(0).real
            expect(MB::Sound::M.round(filter.process(input), 5)).to eq(MB::Sound::M.round(output, 5))
          end
        end
      end

      describe '#response' do
        it 'accepts an NArray for calculating multiple response points' do
          points = Numo::DComplex.linspace(0, Math::PI, 100)
          expect(MB::Sound::M.round(filter.response(points), 4)).to eq(points.map { |v| MB::Sound::M.round(filter.response(v), 4) })
        end
      end
    end
  end

  describe '#z_response' do
    it 'accepts an NArray for calculating multiple response points' do
      grid_size = 20
      points = Numo::DComplex[
        Numo::DComplex.linspace(-1, 1, grid_size).to_enum.map { |v|
          Numo::DComplex.linspace(v - 1i, v + 1i, grid_size)
        }
      ].reshape(grid_size, grid_size)

      f = MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 4800)
      expect(MB::Sound::M.round(f.z_response(points), 4)).to eq(points.map { |v| MB::Sound::M.round(f.z_response(v), 4) })
    end
  end

  describe '#initialize' do
    it 'can initialize a filter chain' do
      expect(chain.filters.length).to eq(3)
    end

    it 'can create a chain with nested chains' do
      c2 = MB::Sound::Filter::FilterChain.new(chain)
      c3 = MB::Sound::Filter::FilterChain.new(c2)

      expect(c3.has_filter?(chain)).to eq(true)
    end

    it 'cannot create a chain with duplication' do
      expect { MB::Sound::Filter::FilterChain.new(chain, chain.filters[0]) }.to raise_error(MB::Sound::Filter::FilterChain::FilterCycleError)
    end

    it 'cannot create a chain that contains an artificially inserted cycle' do
      c2 = MB::Sound::Filter::FilterChain.new(chain)
      c3 = MB::Sound::Filter::FilterChain.new(c2)
      chain.filters << c3

      expect { MB::Sound::Filter::FilterChain.new(chain) }.to raise_error(MB::Sound::Filter::FilterChain::FilterCycleError)
    end
  end

  describe '#chain' do
    it 'returns the existing filter chain instead of creating a new one' do
      expect(chain.chain(123.hz.lowpass)).to equal(chain)
    end

    it 'increases the number of filters in the chain' do
      prior_length = chain.filters.length
      chain.chain(123.hz.lowpass)
      expect(chain.filters.length).to eq(prior_length + 1)
    end

    it 'cannot add the filter chain to itself' do
      expect { chain.chain(chain) }.to raise_error(/Cannot add/)
    end

    it 'cannot create a trivial cycle' do
      c2 = MB::Sound::Filter::FilterChain.new(chain)
      expect { c2.chain(chain) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
      expect { chain.chain(c2) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
    end

    it 'cannot create a more complex cycle' do
      c2 = MB::Sound::Filter::FilterChain.new(chain)
      c3 = MB::Sound::Filter::FilterChain.new(c2)

      expect { c3.chain(chain) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
      expect { chain.chain(c3) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
    end

    it 'cannot add a duplicate' do
      f = 123.hz.lowpass
      chain.chain(f)
      expect { chain.chain(f) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
    end

    it 'cannot chain itself' do
      expect { chain.chain(chain) }.to raise_error(MB::Sound::Filter::FilterChain::FilterDuplicationError)
    end
  end

  describe '#has_filter?' do
    it 'returns true for a filter that is in the chain' do
      expect(chain.filters.map { |f| chain.has_filter?(f) }).to eq(chain.filters.map { true })
    end

    it 'returns false for a filter that is not in the chain' do
      expect(chain.has_filter?(123.hz.lowpass)).to eq(false)
    end

    it 'can follow nested filter chains' do
      c2 = MB::Sound::Filter::FilterChain.new(chain)
      expect(c2.has_filter?(chain.filters[0])).to eq(true)
    end
  end
end
