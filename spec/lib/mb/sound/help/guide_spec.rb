# The user guide (docs/guide/*.md; MB::Sound::Help::Guide): every Ruby
# example of every chapter runs as written, in order, as if typed into one
# console (one Session and one binding per chapter, so a later example can
# use what an earlier one made), and each example that makes sound plays
# near the listening level, like the help topics' examples
# (help_spec.rb).  Song files (`<!-- check: script -->`) run as programs
# rendering with -o.  The text stays in a musician's words.
require 'open3'
require 'rbconfig'
require 'mb/sound/help'

RSpec.describe MB::Sound::Help::Guide do
  chapters = MB::Sound::Help::Guide.chapters

  let(:lib) { File.expand_path('../../../../../lib', __dir__) }

  # Help state and saves go to temp dirs; the monitor trim is restored
  around do |ex|
    old = ENV['MB_SOUND_HELP_DIR']
    old_presets = ENV['MB_SOUND_PRESETS']
    old_trim = MB::Sound::Session.monitor_gain
    ENV['MB_SOUND_HELP_DIR'] = tmp_path('help')
    ENV['MB_SOUND_PRESETS'] = tmp_path('presets')
    MB::Sound::Library.reload!
    ex.run
  ensure
    ENV['MB_SOUND_HELP_DIR'] = old
    ENV['MB_SOUND_PRESETS'] = old_presets
    MB::Sound::Session.monitor_gain = old_trim
    MB::Sound::Library.reload!
  end

  def new_session
    MB::Sound::Session.new(
      master_gain: MB::Sound::Session::DEFAULT_MASTER_GAIN, output: MB::Sound::NullOutput.new(channels: 2, sleep: false),
      transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 800,
      realtime: false, raise_errors: true
    )
  end

  # Plays +bars+ bars at the session's tempo; returns the output channels.
  def play_bars(session, bars)
    t = session.transport
    frames = (t.seconds(t.bar_length * bars) * 48000).to_i
    bufs = Array.new([frames / 800, 1].max) { session.process_buffer(800).map(&:dup) }
    bufs.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }
  end

  def peak_db(channels) = 20 * Math.log10([channels.map { |c| c.abs.max }.max, 1e-9].max)

  def loudness(channels) = MB::Sound.loudness(channels.map { |c| Numo::DFloat.cast(c) }, true_peak: false).integrated

  # The level check tone's peak and loudness (the help examples' yardstick).
  def self.reference
    @reference ||= begin
      s = MB::Sound::Session.new(master_gain: MB::Sound::Session::DEFAULT_MASTER_GAIN, output: MB::Sound::NullOutput.new(channels: 2, sleep: false),
        transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
      MB::Sound::Help::Level::SessionPlayer.new(s).start(0)
      out = Array.new(240) { s.process_buffer(800).map(&:dup) }.transpose.map { |c| Numo::SFloat.zeros(0).concatenate(*c) }
      { peak: 20 * Math.log10(out.map { |c| c.abs.max }.max), loudness: MB::Sound.loudness(out.map { |c| Numo::DFloat.cast(c) }, true_peak: false).integrated }
    ensure
      s&.close
    end
  end

  # Runs a song file example as a program, rendering to a file with -o
  # (+render+) or playing it on a silent output; returns [output, status,
  # file].
  def run_script(chapter, ex, render: true)
    dir = tmp_path("#{chapter.name}_#{ex.line}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, 'song.rb')
    File.write(path, ex.code)
    out_file = File.join(dir, 'song.flac')
    args = render ? ['-o', out_file] : []
    out, status = Open3.capture2e({ 'OUTPUT_TYPE' => 'null' }, 'timeout', '120', RbConfig.ruby, '-I', lib, path, *args, chdir: dir)
    [out, status, out_file]
  end

  chapters.each do |chapter|
    console_examples = chapter.examples.select(&:run?).reject { |ex| ex.program? || ex.script? }
    if console_examples.any?
      it "#{chapter.number} #{chapter.name}: every console example runs as typed, near the listening level", render_budget: { seconds: 240, reason: 'a chapter of examples, each played for its bars' } do
        session = new_session
        ref = self.class.reference
        problems = []
        # (files the examples write land in a folder of their own)
        Dir.chdir(tmp_path("#{chapter.name}_files").tap { |d| FileUtils.mkdir_p(d) }) do
        MB::Sound::Session.with_context(session: session) do
          console = MB::Sound.module_eval('binding')
          console_examples.each do |ex|
            where = "#{File.basename(chapter.path)}:#{ex.line}"
            begin
              console.eval(ex.code, chapter.path, ex.line)
            rescue Exception => e # rubocop:disable Lint/RescueException
              raise e.class, "#{where}: #{e.message}", e.backtrace
            end
            out = play_bars(session, ex.check.key?(:bars) || ex.sound? ? ex.bars + (ex.sound? ? 1 : 0) : 1)
            next unless ex.sound?

            over = peak_db(out) - ref[:peak]
            lufs = loudness(out)
            if over > MB::Sound::Help::Level::EXAMPLE_PEAK_OVER_TONE_DB
              problems << "#{where}: peaks #{over.round(1)} dB over the level tone (at most #{MB::Sound::Help::Level::EXAMPLE_PEAK_OVER_TONE_DB})"
            end
            if (lufs - ref[:loudness]).abs > MB::Sound::Help::Level::EXAMPLE_LOUDNESS_WINDOW
              problems << "#{where}: #{lufs.round(1)} LUFS, the level tone #{ref[:loudness].round(1)} (within #{MB::Sound::Help::Level::EXAMPLE_LOUDNESS_WINDOW} LU)"
            end
          end
        end
        end
        expect(problems).to be_empty, problems.join("\n")
      ensure
        session&.close
      end
    end

    # Song files run as programs, each on its own
    chapter.examples.select { |ex| ex.run? && (ex.program? || ex.script?) }.each do |ex|
      where = "#{File.basename(chapter.path)}:#{ex.line}"
      if ex.program?
        it "#{where}: the song file plays and ends by itself" do
          out, status, = run_script(chapter, ex, render: false)
          expect(status).to be_success, out
          expect(out).not_to match(/warning/i)
        end
      else
        it "#{where}: the song file renders with -o, not clipping, not silent" do
          expect(ex.code).to include('song_script'), 'a song file example renders with -o through song_script'
          out, status, file = run_script(chapter, ex)
          expect(status).to be_success, out
          expect(out).not_to match(/warning/i)
          data = MB::Sound.read(file)
          expect(peak_db(data)).to be <= 0
          expect(loudness(data)).to be > -40
        end
      end
    end
  end

  describe 'chapters' do
    it 'are numbered in order, each with a title and a summary paragraph' do
      expect(chapters.map(&:number)).to eq((1..chapters.length).to_a)
      chapters.each do |c|
        expect(c.title).not_to be_empty, c.path
        expect(c.summary.length).to be > 40, c.path
      end
    end

    it 'link only to chapters that exist' do
      names = chapters.map { |c| File.basename(c.path) } + ['README.md']
      chapters.each do |c|
        links = c.text.scan(/\]\(([\w-]+\.md)(?:#[\w-]*)?\)/).flatten
        expect(links - names).to eq([]), c.path
      end
    end

    it 'run every Ruby block or say why not, and mark checks only on code blocks' do
      chapters.each do |c|
        c.examples.select(&:ruby?).each do |ex|
          expect(ex.check.fetch(:skip, 'why')).not_to be_empty, "#{c.path}:#{ex.line}: skip says why"
        end
        expect(c.text.scan(/<!--\s*check:/).length).to be <= c.examples.length
      end
    end

    # The guide is for musicians: no engine words, no inspirations named
    # (the help wording rule), and no talk of exactness (round 2 of the
    # persona panel: engineer framing turned musicians into testers).
    JARGON = [/plan layer/i, /\bTee\b/, /\bkernel/i, /GraphNode/, /NArray/, /\bexact/i, /bit for bit/i, /buffer size/i, /design\/notes/].freeze

    it 'speaks a musician\'s language' do
      products = /\b(DirectX|Sound Forge|OTT|Serum|Ableton|iZotope|FabFilter|Kontakt|Reaktor|SuperCollider|Sonic Pi|ACID|REX|FluidSynth)\b/
      hits = chapters.flat_map do |c|
        c.text.lines.each_with_index.filter_map do |l, i|
          bad = JARGON.find { |j| l.match?(j) } || (l.match?(products) && products)
          "#{File.basename(c.path)}:#{i + 1}: #{l.strip}" if bad
        end
      end
      expect(hits).to eq([])
    end
  end

  describe 'in the console' do
    def text(x) = MB::U.remove_ansi(x.to_s)

    def walls(page, limit: 9)
      runs = text(page).lines.map(&:chomp).slice_when { |a, b| a.strip.empty? != b.strip.empty? }
      runs.reject { |r| r.first.strip.empty? }.map { |r| r.reject { |l| l.start_with?('    ') } }.select { |r| r.length > limit }
    end

    it 'lists the chapters and the folder with guide, and help :guide' do
      page = text(MB::Sound.guide)
      expect(page).to include(MB::Sound::Help::Guide.dir)
      chapters.each { |c| expect(page).to include(c.title) }
      expect(text(MB::Sound.help(:guide))).to include('guide :', chapters.first.title)
      expect(text(MB::Sound.help(:manual))).to include('The user guide')
    end

    it 'shows a chapter by name, number, or the start of its name, without check comments or walls of text' do
      c = chapters.first
      [c.name, c.number, c.name.to_s[0, 4]].each do |which|
        expect(text(MB::Sound.guide(which))).to include(c.title)
      end
      chapters.each do |ch|
        page = text(MB::Sound.guide(ch.name))
        expect(page).not_to include('<!--', '```')
        expect(walls(page)).to eq([]), ch.path
        expect(page.lines.reject { |l| l.start_with?('    ') }.map { |l| l.chomp.length }.max).to be <= 100 # (prose; code lines stay whole)
      end
    end

    it 'names the chapters when one is missing' do
      expect { MB::Sound.guide(:drumz) }.to raise_error(ArgumentError, /No guide chapter :drumz.*chapters: :/)
    end
  end
end
