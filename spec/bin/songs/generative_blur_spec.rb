RSpec.describe('bin/songs/generative_blur.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/generative_blur.rb', __dir__) }

  after { MB::Sound.rewind }

  describe 'numeric clouds (grains a second)' do
    let(:slots_per_second) { 84 / 240.0 }

    it 'hits the rate on the coarsest grid with a chance of at most 0.9' do
      { 8 => 128, 40 => 128, 41 => 256, 60 => 256, 80 => 256, 100 => 512, 160 => 512 }.each do |rate, division|
        c = MB::Sound.generative_blur_cloud_settings(rate)
        expect(c[:division]).to eq(division), "#{rate}/s"
        expect(c[:chance]).to be <= 0.9
        expect(c[:chance] * division * slots_per_second).to be_within(1e-9).of(rate)
      end
    end

    it 'keeps 350 ms grains up to 40 a second, then about 14 overlapping, and scales the level by sqrt(14 / overlap)' do
      expect(MB::Sound.generative_blur_cloud_settings(40)).to include(size: 0.35, gain: 0.2)
      c = MB::Sound.generative_blur_cloud_settings(60)
      expect(c[:size]).to be_within(1e-12).of(14 / 60.0)
      expect(c[:gain]).to be_within(1e-12).of(0.2)
      c = MB::Sound.generative_blur_cloud_settings(8)
      expect(c[:gain]).to be_within(1e-12).of(0.2 * Math.sqrt(14 / 2.8))
      expect(MB::Sound.generative_blur_cloud_settings(1)[:gain]).to be_within(1e-12).of(0.2 * Math.sqrt(14))
    end

    it 'refuses rates outside 0.5..160 and other values, saying what is allowed' do
      [0, -3, 0.1, 1000, :thick, 'abc'].each do |bad|
        expect { MB::Sound.generative_blur_cloud_settings(bad) }.to raise_error(ArgumentError, /0\.5 to 160/)
      end
      expect { MB::Sound.render(tmp_path('x.flac'), bars: 0.1) { MB::Sound.generative_blur(mode: :grains, cloud: :thick) } }
        .to raise_error(ArgumentError, /:dense, :sparse, or grains a second/)
    end

    it 'renders a cloud at a numeric rate' do
      path = tmp_path('cloud.flac')
      MB::Sound.render(path, bars: 0.5) { MB::Sound.generative_blur(mode: :grains, cloud: 60, bass: false) }
      data = MB::Sound.read(path)
      expect(data.map { |c| c.abs.max }.max).to be > 0.05
    end

    it 'defaults to 120 grains a second (the maintainer pick), keeping -c dense for the earlier cloud' do
      expect(MB::Sound.method(:generative_blur).parameters).to include([:key, :cloud])
      default = MB::Sound.render(tmp_path('a.flac'), bars: 0.25) { MB::Sound.generative_blur(mode: :grains, bass: false) }
      a = MB::Sound.read(tmp_path('a.flac'))
      MB::Sound.rewind
      MB::Sound.render(tmp_path('b.flac'), bars: 0.25) { MB::Sound.generative_blur(mode: :grains, cloud: 120, bass: false) }
      expect(MB::Sound.read(tmp_path('b.flac'))).to eq(a)
      expect(default).to be > 0

      out = `#{RbConfig.ruby} bin/songs/generative_blur.rb --help 2>&1`
      expect(out).to match(/--cloud VALUE.*\(default 120\)$/)
    end
  end
end
