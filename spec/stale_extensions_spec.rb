require_relative 'support/stale_extensions'

RSpec.describe(StaleExtensions) do
  let(:root) { tmp_path('repo') }
  let(:dlext) { RbConfig::CONFIG['DLEXT'] }

  def write(rel, mtime)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, rel)
    File.utime(mtime, mtime, path)
  end

  before do
    t = Time.now - 100
    write('ext/mb/sound/fast_x/extconf.rb', t)
    write('ext/mb/sound/fast_x/fast_x.c', t)
    write('ext/mb/sound/fast_x/depend', t)
    File.write(File.join(root, 'ext/mb/sound/fast_x/depend'), "fast_x.o: $(srcdir)/../include/mb_x.h\n")
    File.utime(t, t, File.join(root, 'ext/mb/sound/fast_x/depend'))
    write('ext/mb/sound/include/mb_x.h', t)
    write('ext/mb/sound/include/mb_unused.h', t)
    write('ext/mb/fast_sound/extconf.rb', t)
    write('gems/mb-term/ext/mb/term/fast_term/extconf.rb', t)
    write("lib/mb/sound/fast_x.#{dlext}", t + 10)
    write("lib/mb/fast_sound.#{dlext}", t + 10)
    write("gems/mb-term/lib/mb/term/fast_term.#{dlext}", t + 10)
  end

  it 'finds nothing when every library is newer than its sources' do
    expect(StaleExtensions.problems(root)).to eq([])
  end

  it 'finds a library older than its source, or than a shared header its depend file lists' do
    write('ext/mb/sound/fast_x/fast_x.c', Time.now)
    expect(StaleExtensions.problems(root)).to eq([["lib/mb/sound/fast_x.#{dlext}", 'older than ext/mb/sound/fast_x/fast_x.c']])

    write('ext/mb/sound/fast_x/fast_x.c', Time.now - 100)
    write('ext/mb/sound/include/mb_unused.h', Time.now)
    expect(StaleExtensions.problems(root)).to eq([])
    write('ext/mb/sound/include/mb_x.h', Time.now)
    expect(StaleExtensions.problems(root)).to eq([["lib/mb/sound/fast_x.#{dlext}", 'older than ext/mb/sound/include/mb_x.h']])
  end

  it "finds missing libraries, including fast_sound's and the gems'" do
    File.delete(File.join(root, "lib/mb/fast_sound.#{dlext}"))
    File.delete(File.join(root, "gems/mb-term/lib/mb/term/fast_term.#{dlext}"))
    expect(StaleExtensions.problems(root).map(&:first)).to contain_exactly("lib/mb/fast_sound.#{dlext}", "gems/mb-term/lib/mb/term/fast_term.#{dlext}")
  end

  it 'finds nothing stale in this checkout (spec_helper would have stopped the run)' do
    expect(StaleExtensions.problems).to eq([])
  end
end
