# Guards LibraryFiles (spec/support/library_files.rb): the files the
# every-class guards require must not change the process when loaded.
RSpec.describe(LibraryFiles) do
  it 'lists only files that exist' do
    LibraryFiles::SKIP.each_key do |rel|
      expect(File.exist?(File.join(LibraryFiles::LIB, rel))).to eq(true), "#{rel} in LibraryFiles::SKIP doesn't exist"
    end
  end

  it 'leaves out every lib file that extends the top-level object when loaded' do
    extenders = Dir[File.join(LibraryFiles::LIB, 'mb/sound/**/*.rb')].select { |f|
      File.read(f).match?(/\bmain\.extend\b|TOPLEVEL_BINDING\.receiver\.extend\b/)
    }.map { |f| f.delete_prefix("#{LibraryFiles::LIB}/") }
    expect(extenders - LibraryFiles::SKIP.keys).to eq([])
  end

  it 'gives the top-level object no DSL commands after loading every listed file' do
    LibraryFiles.require_all
    main = TOPLEVEL_BINDING.receiver
    expect(main.singleton_class.include?(MB::Sound::DSL)).to eq(false) if defined?(MB::Sound::DSL)
    expect(main.singleton_methods).not_to include(:take)
  end
end
