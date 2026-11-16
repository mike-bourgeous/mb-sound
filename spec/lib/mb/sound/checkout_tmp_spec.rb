# $MB_SOUND_CHECKOUT_TMP (sd-ux-fixes-1, after the review's #28 incident: a
# review agent's tuner runs from a worktree wrote the main checkout's tmp/
# and replaced one of the maintainer's fit files): one variable moves every
# file the console keeps in the main checkout's tmp/, with the specific
# overrides still winning.  The guard below fails a new reader of
# Internal.checkout_tmp_dir or main_checkout that this spec doesn't check.
RSpec.describe('MB_SOUND_CHECKOUT_TMP', :aggregate_failures) do
  OVERRIDES = %w[MB_SOUND_CHECKOUT_TMP MB_SOUND_FITS MB_SOUND_UI_NOTES MB_SOUND_BENCH_DIR MB_SOUND_TUNE_QUEUE MB_SOUND_REFS].freeze

  # The lib/ files reading the main checkout's tmp/, each checked below.
  READERS = {
    'lib/mb/sound/fit_patch.rb' => 'FitPatch.dir (fits/; the tuner\'s files sit beside it)',
    'lib/mb/sound/ui/note_log.rb' => 'NoteLog.dir (ui-notes/)',
    'lib/mb/sound/ui/perf.rb' => 'Perf.captures_dir (ui-perf/captures/, ui.perf :save and :capture)',
    'lib/mb/sound/library/bench.rb' => 'Bench.default_root (listening/)',
    'lib/mb/sound/internal.rb' => 'the definitions',
  }.freeze

  around do |ex|
    saved = OVERRIDES.to_h { |k| [k, ENV[k]] }
    begin
      ex.run
    ensure
      saved.each { |k, v| ENV[k] = v }
    end
  end

  it 'moves fits, the tuner\'s files, ui notes, and Bench sets, and the specific overrides win' do
    root = tmp_path('scratch')
    OVERRIDES.each { |k| ENV[k] = nil }
    ENV['MB_SOUND_CHECKOUT_TMP'] = root
    wiz = MB::Sound::HandTune::Wizard
    expect(MB::Sound::Internal.checkout_tmp_dir).to eq(root)
    expect(MB::Sound::FitPatch.dir).to eq(File.join(root, 'fits'))
    expect(wiz.home).to eq(root)
    expect(wiz.state_path).to eq(File.join(root, 'tuner.json'))
    expect(wiz.queue_dir).to eq(File.join(root, 'hand-tune-queue'))
    expect(wiz.default_folder).to eq(File.join(root, 'refs'))
    expect(MB::Sound::UI::NoteLog.dir).to eq(File.join(root, 'ui-notes'))
    expect(MB::Sound::Library::Bench.default_root).to eq(File.join(root, 'listening'))

    ENV['MB_SOUND_FITS'] = tmp_path('fits')
    ENV['MB_SOUND_UI_NOTES'] = tmp_path('notes')
    ENV['MB_SOUND_BENCH_DIR'] = tmp_path('bench')
    expect(MB::Sound::FitPatch.dir).to eq(tmp_path('fits'))
    expect(MB::Sound::UI::NoteLog.dir).to eq(tmp_path('notes'))
    expect(MB::Sound::Library::Bench.default_root).to eq(tmp_path('bench'))

    ENV['MB_SOUND_CHECKOUT_TMP'] = ''
    expect(MB::Sound::Internal.checkout_tmp_override).to be_nil
  end

  it 'knows every lib/ reader of the main checkout\'s tmp/' do
    root = File.expand_path('../../../..', __dir__)
    found = Dir.glob('lib/**/*.rb', base: root).select { |f|
      File.foreach(File.join(root, f)).any? { |l| !l.lstrip.start_with?('#') && l.match?(/(?:Internal\.|def )(?:checkout_tmp_dir|main_checkout)\b/) }
    }
    expect(found.sort).to eq(READERS.keys.sort), "check each new reader here (it should follow MB_SOUND_CHECKOUT_TMP): #{(found - READERS.keys).join(', ')}"
  end
end
