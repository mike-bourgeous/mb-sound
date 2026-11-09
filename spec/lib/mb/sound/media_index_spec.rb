RSpec.describe MB::Sound::MediaIndex do
  let(:root) { File.dirname(tmp_path('media/x')) }

  def touch(*names)
    names.each do |f|
      FileUtils.mkdir_p(File.join(root, File.dirname(f)))
      File.write(File.join(root, f), 'x')
    end
  end

  def at(f) = File.join(root, f)

  before { described_class.clear_cache }
  after { described_class.clear_cache }

  describe '#resolve' do
    before do
      touch('pack/Drums/Kick.wav', 'song/drums/kick.wav', 'other/kick.wav', 'pack/clip.mid', '.hidden/clip.mid', 'pads/Wärm.wav')
    end

    it 'finds a file by its name in any case, from Windows and POSIX paths' do
      idx = described_class.new(root)
      m = idx.resolve('C:\\Users\\x\\Projects\\CLIP.MID')
      expect(m.status).to eq(:found)
      expect(m.path).to eq(at('pack/clip.mid'))
      expect(m.folders).to eq(0)
      expect(m.candidates).to eq([at('pack/clip.mid')])
      expect(idx['/home/y/clip.mid']).to eq(at('pack/clip.mid'))
      expect(idx.find('clip.mid')).to eq(at('pack/clip.mid'))
    end

    it 'chooses among same-named files by the most matching trailing folders' do
      idx = described_class.new(root)
      m = idx.resolve('D:\\Music\\song\\Drums\\KICK.wav')
      expect(m.status).to eq(:ambiguous)
      expect(m.path).to eq(at('song/drums/kick.wav'))
      expect(m.folders).to eq(2)
      expect(m.tied).to eq(1)
      expect(m.candidates.first).to eq(at('song/drums/kick.wav'))
      expect(m.candidates.sort).to eq([at('other/kick.wav'), at('pack/Drums/Kick.wav'), at('song/drums/kick.wav')].sort)

      # A later folder decides: pack/Drums beats song/drums for .../pack/drums
      expect(idx['D:\\pack\\drums\\kick.wav']).to eq(at('pack/Drums/Kick.wav'))
    end

    it 'takes the first in path order when matching folders tie, and says how many tied' do
      m = described_class.new(root).resolve('D:\\x\\Kick.wav')
      expect(m.tied).to eq(3)
      expect(m.folders).to eq(0)
      expect(m.path).to eq(at('other/kick.wav'))
      expect(m.message).to match(/3 files named kick\.wav for D:\\x\\Kick\.wav: chose .*other\/kick\.wav \(3 tied at 0 matching folders, took the first\); others: /)
    end

    it 'counts the media root\'s own folder names' do
      m = described_class.new(at('pack')).resolve('E:\\Samples\\pack\\Drums\\Kick.wav')
      expect(m.folders).to eq(2) # Drums and the root, pack
    end

    it 'reports missing files' do
      m = described_class.new(root).resolve('C:\\x\\none.wav')
      expect(m).to have_attributes(status: :missing, path: nil, folders: nil, candidates: [], found?: false, missing?: true)
      expect(described_class.new(root).resolve('').status).to eq(:missing)
    end

    it 'matches names in any Unicode normalization' do
      nfd = "W\u0061\u0308rm.WAV"
      expect(described_class.new(root)["X:\\#{nfd}"]).to eq(at('pads/Wärm.wav'))
    end

    it 'warns once per saved path and choice with warn: true' do
      idx = described_class.new(root)
      expect {
        2.times { idx.resolve('D:\\song\\drums\\kick.wav', warn: true) }
      }.to output(/\AMediaIndex: 3 files named kick\.wav[^\n]*2 matching folders\)[^\n]*\n\z/).to_stderr
      expect { idx.resolve('D:\\song\\drums\\kick.wav') }.not_to output.to_stderr
    end
  end

  describe 'the index' do
    it 'leaves out dot files and folders unless hidden: true' do
      touch('a/clip.mid', '.hidden/clip.mid', 'b/.clip.mid')
      expect(described_class.new(root).files('clip.mid')).to eq([at('a/clip.mid')])
      expect(described_class.new(root).files('.clip.mid')).to eq([])
      expect(described_class.new(root, hidden: true).files('CLIP.mid')).to eq([at('.hidden/clip.mid'), at('a/clip.mid')])
      expect(described_class.new(root, hidden: true).size).to eq(3)
    end

    it 'limits the index to extensions:' do
      touch('a.wav', 'b.WAV', 'c.flac', 'd.mid')
      expect(described_class.new(root, extensions: %w[wav .flac]).size).to eq(3)
      expect(described_class.new(root, extensions: %w[wav])['d.mid']).to be_nil
    end

    it 'lists names shared by several files' do
      touch('x/A.wav', 'y/a.wav', 'z/b.wav')
      expect(described_class.new(root).ambiguous).to eq('a.wav' => [at('x/A.wav'), at('y/a.wav')])
    end

    it 'lists links to files, not into linked folders' do
      touch('real/a.wav')
      File.symlink(at('real/a.wav'), at('link.wav'))
      File.symlink(at('real'), at('linked'))
      idx = described_class.new(root)
      expect(idx.files('a.wav')).to eq([at('real/a.wav')])
      expect(idx.files('link.wav')).to eq([at('link.wav')])
    end

    it 'raises for a missing root' do
      expect { described_class.new(at('none')) }.to raise_error(ArgumentError, /No media folder/)
    end
  end

  describe '.for' do
    it 'reuses the index until a folder changes' do
      touch('a/one.wav')
      idx = described_class.for(root)
      expect(described_class.for(root + '/')).to equal(idx)
      expect(described_class.for(root, hidden: true)).not_to equal(idx)

      # A folder's mtime changes when a file is added (set one explicitly so
      # filesystems with coarse mtimes still see a change)
      touch('a/two.wav')
      File.utime(Time.now + 10, Time.now + 10, at('a'))
      expect(idx.fresh?).to eq(false)
      again = described_class.for(root)
      expect(again).not_to equal(idx)
      expect(again['two.wav']).to eq(at('a/two.wav'))
    end

    it 'keeps at most CACHE_SIZE indexes' do
      stub_const('MB::Sound::MediaIndex::CACHE_SIZE', 2)
      dirs = 3.times.map { |i| File.dirname(tmp_path("m#{i}/x")).tap { |d| FileUtils.mkdir_p(d) } }
      first = described_class.for(dirs[0])
      described_class.for(dirs[1])
      described_class.for(dirs[2])
      expect(described_class.for(dirs[0])).not_to equal(first)
    end
  end
end
