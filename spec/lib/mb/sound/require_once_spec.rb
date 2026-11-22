require 'open3'
require 'rbconfig'

RSpec.describe(MB::Sound::RequireOnce) do
  # Runs +code+ in a plain Ruby (RequireOnce loaded, not installed, unless
  # the code installs it; no global change to the spec process) with a
  # directory first on the load path holding a shadowing io/console.rb:
  # Ruby finds that file only by searching the load path again (an open()
  # per directory, holding the GVL: over a network mount of the checkout,
  # a dropout per console line).  Returns stdout.
  def run_ruby(code)
    dir = tmp_path('shadow')
    FileUtils.mkdir_p(File.join(dir, 'io'))
    File.write(File.join(dir, 'io', 'console.rb'), "$shadow = true\n")
    File.write(File.join(dir, 'mb_require_once_probe.rb'), "$loads = ($loads || 0) + 1\n")
    script = "require 'io/console'; require 'mb/sound/require_once'; $shadow = false; SHADOW = #{dir.inspect}\n#{code}"
    out, err, st = Open3.capture3(RbConfig.ruby, '--disable-gems', '-I', File.expand_path('../../../../lib', __dir__), '-e', script)
    raise "ruby failed: #{err}" unless st.success?

    out
  end

  it 'shows the problem without it: Ruby searches the load path again for an extension already loaded' do
    expect(run_ruby("$LOAD_PATH.unshift(SHADOW); require 'io/console'; print $shadow")).to eq('true')
  end

  it 'returns at once for a feature already required, without searching the load path' do
    out = run_ruby(<<~'RUBY')
      MB::Sound::RequireOnce.install
      $LOAD_PATH.unshift(SHADOW)
      print [require('io/console'), $shadow].inspect
    RUBY
    expect(out).to eq('[false, false]')
  end

  it 'does what require does for a feature not seen yet, and starts over when $LOADED_FEATURES shrinks' do
    out = run_ruby(<<~'RUBY')
      MB::Sound::RequireOnce.install
      $LOAD_PATH.unshift(SHADOW)
      r = [require('mb_require_once_probe'), require('mb_require_once_probe'), $loads]
      $LOADED_FEATURES.delete(File.join(SHADOW, 'mb_require_once_probe.rb'))
      r += [require('mb_require_once_probe'), $loads]
      print r.inspect
    RUBY
    expect(out).to eq('[true, false, 1, true, 2]')
  end

  it 'does nothing with MB_SOUND_REQUIRE_ONCE=0' do
    out = run_ruby("ENV['MB_SOUND_REQUIRE_ONCE'] = '0'; print MB::Sound::RequireOnce.install.inspect, MB::Sound::RequireOnce.installed?.inspect")
    expect(out).to eq('falsefalse')
  end

  it 'never keeps mb-sound features or paths (another checkout may be loaded over them)' do
    described_class.reset
    %w[mb/sound/x /abs/path.rb ./rel].each { |f| described_class.note(f) }
    expect(%w[mb/sound/x /abs/path.rb ./rel].map { |f| described_class.done?(f) }).to eq([false, false, false])
    described_class.note('json')
    expect(described_class.done?('json')).to eq(true)
    described_class.reset
  end

  it 'is installed by the console' do
    expect(File.read(File.expand_path('../../../../bin/sound.rb', __dir__))).to include('MB::Sound::RequireOnce.install')
  end

  # followups-1: a script playing live holds a realtime Session too (its
  # prints and lazy loads); a render to a file doesn't install it, nor
  # does MB_SOUND_REQUIRE_ONCE=0.  Real processes: the spec process opts
  # out (ScriptRunner.require_once, spec_helper).
  describe 'in scripts' do
    def run_song(*args, env: {})
      script = tmp_path('ro_song.rb')
      File.write(script, <<~RUBY)
        require 'bundler/setup'
        require 'mb-sound'
        include MB::Sound::ScriptingMethods
        at_exit { $stdout.print "installed=\#{MB::Sound::RequireOnce.installed?}" }
        song_script { MB::Sound.bpm 240; MB::Sound.bg(:ro, 220.hz.sine.at(-30.db), fade: 0) }
      RUBY
      out, err, st = Open3.capture3({ 'OUTPUT_TYPE' => 'null', 'MB_SOUND_REQUIRE_ONCE' => nil }.merge(env),
                                    RbConfig.ruby, script, '-q', '--bars', '0.25', *args,
                                    chdir: File.expand_path('../../../..', __dir__))
      raise "script failed: #{err}" unless st.success?

      out[/installed=\w+/]
    end

    it 'installs it for live playback, not for a render or with MB_SOUND_REQUIRE_ONCE=0' do
      expect(run_song).to eq('installed=true')
      expect(run_song('-o', tmp_path('ro.flac'))).to eq('installed=false')
      expect(run_song(env: { 'MB_SOUND_REQUIRE_ONCE' => '0' })).to eq('installed=false')
    end
  end
end
