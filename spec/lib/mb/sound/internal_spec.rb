RSpec.describe(MB::Sound::Internal) do
  describe '.user_data_dir' do
    it 'joins its parts under the platform data directory' do
      dir = described_class.user_data_dir('takes', :tmp)
      if RbConfig::CONFIG['host_os'] =~ /darwin/
        expect(dir).to eq(File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'takes', 'tmp'))
      else
        base = ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME']
        expect(dir).to eq(File.join(base, 'mb-sound', 'takes', 'tmp'))
      end
    end

    it 'follows XDG_DATA_HOME off macOS', if: RbConfig::CONFIG['host_os'] !~ /darwin/ do
      old = ENV['XDG_DATA_HOME']
      ENV['XDG_DATA_HOME'] = '/x/data'
      expect(described_class.user_data_dir('presets')).to eq('/x/data/mb-sound/presets')
      expect(MB::Sound::GraphIO.user_presets_dir).to eq('/x/data/mb-sound/presets') unless ENV['MB_SOUND_USER_PRESETS']
      expect(MB::Sound::Take.data_dir).to eq('/x/data/mb-sound/takes')
    ensure
      ENV['XDG_DATA_HOME'] = old
    end
  end

  describe '.checkout_dir and .scratch_dir' do
    it 'names this checkout and its tmp/ when mb-sound runs from one (as the specs do)' do
      expect(described_class.checkout_dir).to eq(described_class::GEM_ROOT)
      expect(described_class.scratch_dir('debug')).to eq(File.join(described_class::GEM_ROOT, 'tmp', 'debug'))
      expect(MB::Sound::Take.tmp_dir).to eq(File.join(described_class::GEM_ROOT, 'tmp', 'takes'))
    end

    it 'uses the user data directory for an installed gem (no checkout)' do
      allow(described_class).to receive(:checkout_dir).and_return(nil)
      expect(described_class.scratch_dir('debug')).to eq(described_class.user_data_dir('tmp', 'debug'))
      expect(MB::Sound::Take.tmp_dir).to eq(described_class.user_data_dir('tmp', 'takes'))
    end

    it 'is nil without a Gemfile beside lib/ (an installed gem ships none)' do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(File.join(described_class::GEM_ROOT, 'Gemfile')).and_return(false)
      expect(described_class.checkout_dir).to be_nil
    end
  end
end
