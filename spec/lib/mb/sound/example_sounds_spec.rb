RSpec.describe(MB::Sound::ExampleSounds) do
  let(:shipped) { File.join(MB::Sound::Internal::GEM_ROOT, 'sounds', 'sine', 'sine_100_1s_mono.flac') }

  it "reads mb-sound's copy of a sounds/ file missing from the working directory" do
    Dir.chdir(FileUtils.mkdir_p(tmp_path('room')).first) do
      expect(described_class.resolve('sounds/sine/sine_100_1s_mono.flac')).to eq(shipped)
      data = MB::Sound.read('sounds/sine/sine_100_1s_mono.flac')
      expect(data[0].length).to eq(48000)
    end
  end

  it 'leaves other names alone: a file in the working directory, other folders, .. names, missing files' do
    Dir.chdir(FileUtils.mkdir_p(tmp_path('room')).first) do
      FileUtils.mkdir_p('sounds')
      FileUtils.cp(shipped, 'sounds/mine.flac')
      expect(described_class.resolve('sounds/mine.flac')).to eq('sounds/mine.flac')
      expect(described_class.resolve('other/drums.flac')).to eq('other/drums.flac')
      expect(described_class.resolve('sounds/../sounds/drums.flac')).to eq('sounds/../sounds/drums.flac')
      expect(described_class.resolve('sounds/none.flac')).to eq('sounds/none.flac')
      expect(described_class.resolve(:x)).to eq(:x)
    end
  end

  it "leaves a graph document's names to the document's rules" do
    ctx = MB::Sound::GraphIO::FileGuard::Context.new(tmp_path('doc'), 'test')
    name = MB::Sound::GraphIO::FileGuard.register(+'sounds/drums.flac', ctx)
    expect(described_class.resolve(name)).to equal(name)
  end
end
