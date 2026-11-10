# The clean-room smoke test of a local release (`rake release:smoke DIR=...`
# after `rake release:local DIR=...`; design/notes/release.md): mb-sound as a
# musician runs it after `gem install`, in an empty directory with only the
# installed gems, a fresh HOME, no Bundler, no checkout, and OUTPUT_TYPE=null.
# Each check runs Ruby (or the installed `sound.rb`) as its own process in
# DIR/room and looks at its output and the files it made.  Prints one line
# per check and the output of failures; #run returns true if all passed.
require 'fileutils'
require 'open3'
require 'timeout'

module MB
  module Sound
    class CleanRoomSmoke
      Check = Struct.new(:name, :ok, :detail)

      def initialize(release, io: $stdout)
        @release = release
        @io = io
        @checks = []
      end

      def run
        raise "no install in #{@release.gem_home} (rake release:local)" unless Dir.exist?(File.join(@release.gem_home, 'gems'))
        FileUtils.rm_rf([@release.room, @release.home])
        FileUtils.mkdir_p([@release.room, @release.home])
        @gem_root = ruby('print Gem::Specification.find_by_name("mb-sound").gem_dir').first
        gem_files_before = gem_tree

        check_load
        check_song_file
        check_playback
        check_help
        check_library
        check_examples
        check_console
        check_scripts

        added = gem_tree - gem_files_before
        record('nothing written into the installed gem', added.empty?, added.first(10).join("\n"))
        stray = Dir.children(@release.room) - %w[song.rb song.flac play.rb examples.rb lib.rb console_take.flac hall.flac]
        record('nothing unexpected in the working directory', stray.empty?, stray.join("\n"))

        failed = @checks.reject(&:ok)
        @io.puts "release:smoke: #{@checks.length - failed.length} of #{@checks.length} checks passed#{failed.empty? ? '' : "; failed: #{failed.map(&:name).join(', ')}"}"
        failed.empty?
      end

      private

      # Runs Ruby +code+ in the room (a file when +file+ is given).  Returns
      # [stdout, stderr, status].
      def ruby(code = nil, file: nil, args: [], stdin: nil, timeout: 300)
        cmd = file ? ['ruby', file, *args] : ['ruby', '-e', code, *args]
        capture(cmd, stdin: stdin, timeout: timeout)
      end

      def capture(cmd, stdin: nil, timeout: 300)
        Timeout.timeout(timeout) do
          Open3.capture3(@release.clean_env, *cmd, chdir: @release.room, unsetenv_others: true, stdin_data: stdin.to_s)
        end
      rescue Timeout::Error
        ['', "timed out after #{timeout} s", nil]
      end

      def record(name, ok, detail = nil)
        @checks << Check.new(name, ok, detail)
        @io.puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
        @io.puts(detail.to_s.lines.last(25).map { |l| "     #{l}" }.join) if !ok && detail && !detail.empty?
      end

      def record_run(name, result, &expect)
        out, err, status = result
        ok = status&.success? && (expect.nil? || expect.call(out, err))
        record(name, ok, "#{out}#{err}#{" (#{status})" unless status&.success?}")
        out
      end

      def gem_tree
        Dir.glob('**/*', File::FNM_DOTMATCH, base: @gem_root).reject { |f| f.end_with?('.') }
      end

      # Peak and length of a sound file, read in the clean room.
      def file_stats(path)
        out, = ruby("require 'mb/sound'; d = MB::Sound.read(ARGV[0]); print [d.map { |c| c.abs.max }.max, d[0].length].join(' ')", args: [path])
        peak, frames = out.split.map(&:to_f)
        [peak || 0, frames.to_i]
      end

      def check_load
        record_run('require mb/sound (no checkout files, every extension loaded)', ruby(<<~RUBY)) { |out, _| out.include?('checkout 0') && out[/missing (\d+)/, 1] == '0' }
          require 'mb/sound'
          checkout = $LOADED_FEATURES.count { |f| f.start_with?(#{LocalRelease::ROOT.inspect} + '/') }
          spec = Gem::Specification.find_by_name('mb-sound')
          built = Dir[File.join(spec.extension_dir, '**', '*.so')].map { |f| File.basename(f) }
          loaded = $LOADED_FEATURES.grep(/\\.so\\z/).map { |f| File.basename(f) }
          puts "version \#{MB::Sound::VERSION} checkout \#{checkout} extensions \#{built.length} missing \#{(built - loaded).length} \#{(built - loaded).join(' ')}"
        RUBY
      end

      def check_song_file
        File.write(File.join(@release.room, 'song.rb'), <<~RUBY)
          require 'mb/sound/dsl'

          render('song.flac', bars: 2) do
            bpm 124
            bass = seq(A1, R, A1, C2, R, E2, D2, R).n8.repeat(2)
            bg :bass, bass.synth(voices: 1) { |v| v.hz.saw.lp4(v.cutoff(900), resonance: 0.4) * v.amp_env }.at(-6.db)
            bg :hat, grid(16, 'x.x.x.x.x.x.x.xx').repeat(2)
          end
        RUBY
        record_run('a song file renders (require mb/sound/dsl; render)', ruby(file: 'song.rb'))
        peak, frames = file_stats('song.flac')
        record("song.flac has sound (peak #{peak.round(3)}, #{frames} frames)", peak > 0.01 && frames > 48000 * 3)
      end

      def check_playback
        File.write(File.join(@release.room, 'play.rb'), <<~RUBY)
          require 'mb/sound/dsl'

          bpm 124
          bg :hat, grid(16, 'x.x.x.x.x.x.x.xx').repeat(1)
          play 220.hz.triangle.at(-20.db).until(0.25)
          puts 'played'
        RUBY
        record_run('a song file plays through NullOutput and ends', ruby(file: 'play.rb', timeout: 120)) { |out, _| out.include?('played') }
      end

      def check_help
        record_run('help pages print (help, :play, :tones, :sequences; no design notes)', ruby(<<~RUBY)) { |out, _| out.include?('ends here') && out.lines.length > 100 && !out.include?('design/notes') }
          require 'mb/sound/dsl'
          [help, help(:play), help(:tones), help(:sequences), help(:library)].each { |page| puts page }
          puts 'ends here'
        RUBY
        record_run('lessons list', ruby("require 'mb/sound/dsl'; puts lesson")) { |out, _| out.length > 100 }
      end

      def check_library
        File.write(File.join(@release.room, 'lib.rb'), <<~RUBY)
          require 'mb/sound/dsl'

          puts shelves.inspect
          puts find('dark bass')
          render('hall.flac', bars: 2) { bg :keys, preset(:tine_piano, midi: seq(A3, C4, E4, G4).n8.repeat(2)) }
        RUBY
        record_run('library shelves, find, an instrument preset rendered', ruby(file: 'lib.rb')) { |out, _| out.include?('builtin') }
        peak, = file_stats('hall.flac')
        record("the preset render has sound (peak #{peak.round(3)})", peak > 0.001)
      end

      # README and help examples name files under sounds/ (shipped in the gem).
      def check_examples
        File.write(File.join(@release.room, 'examples.rb'), <<~RUBY)
          require 'mb/sound/dsl'

          data = read 'sounds/sine/sine_100_1s_mono.flac'
          puts "read \#{data[0].length}"
          play Sample['sounds/drums_short.flac'].trim(...0.5.seconds), gain: -8.db
          play file_input('sounds/synth0.flac').until(0.3)
          puts 'examples done'
        RUBY
        record_run("README/help examples' sounds/ files", ruby(file: 'examples.rb', timeout: 120)) { |out, _| out.include?('examples done') }
      end

      def check_console
        input = <<~RUBY
          puts 40 + 2
          puts "slice \#{ENV['RUBY_THREAD_TIMESLICE']} yjit \#{RubyVM::YJIT.enabled?}"
          help :play
          render 'console_take.flac', 110.hz.saw.at(-12.db).until(0.5)
          take.save :tmp
          debug_dump
        RUBY
        out = record_run("the console (the installed sound.rb) runs piped lines, with the shebang's time slice and YJIT", capture(['sound.rb'], stdin: input, timeout: 300)) { |o, _|
          o.include?('42') && o.include?('slice 10 yjit true') && o.include?('Saved the take')
        }
        data = @release.clean_env['HOME']
        record('takes and debug dumps go to the user data directory', Dir.glob(File.join(data, '**', 'take_*.rb'), File::FNM_DOTMATCH).any? && Dir.glob(File.join(data, '**', 'debug', '*'), File::FNM_DOTMATCH).any?, out.to_s.lines.grep(/take|debug/i).join)
      end

      # bin/ scripts ship in the gem: a few run from there by path.
      def check_scripts
        bin = File.join(@gem_root, 'bin')
        record_run('bin/play.rb --help from the gem', capture(['ruby', File.join(bin, 'play.rb'), '--help'])) { |out, _| out.include?('Usage') || out.include?('usage') }
        reverb = File.join(bin, 'effects', 'reverb.rb')
        record_run('bin/effects/reverb.rb renders a file', capture(['ruby', reverb, '-f', File.join(@gem_root, 'sounds', 'drums_short.flac'), '-o', File.join(@release.home, 'reverb.flac')]))
      end
    end
  end
end
