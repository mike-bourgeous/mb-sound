require 'open3'
require 'rbconfig'

# The top-level DSL (lib/mb/sound/dsl.rb) changes the process's top level, so
# every case runs a song file as a real process (never required here: specs'
# top-level blocks would then resolve C4 and friends).
RSpec.describe('mb/sound/dsl') do
  let(:lib) { File.expand_path('../../../../lib', __dir__) }

  # Runs Ruby +code+ as a file in a temporary directory, returning
  # [stdout + stderr, status].
  def run_song(code, name: 'song.rb', args: [])
    path = tmp_path(name)
    File.write(path, code)
    Open3.capture2e({ 'OUTPUT_TYPE' => 'null' }, RbConfig.ruby, '-I', lib, path, *args, chdir: File.dirname(path))
  end

  it 'gives a plain song file the console commands and constants, waiting for the background session at its end' do
    out, status = run_song(<<~RUBY)
      # (registered before the DSL's wait: runs after it)
      at_exit { puts "frames \#{$frames}" }

      require 'mb/sound/dsl'

      $frames = 0
      bpm 150
      bg :bass, seq(A1, R, C2, E2).n16.loop.synth(voices: 1) { |v| v.hz.saw.lp4(800) * v.amp_env }.until(0.25)
      MB::Sound::Session.current.add_tap { |mix| $frames += mix[0].length }
      puts [C4.class, R.equal?(MB::Sound::R), Session.name, respond_to?(:play), Object.respond_to?(:bg)].inspect

      # Other classes and modules are unchanged
      class Foo
        def self.note = C4
        def bg = :mine
      end
      begin
        Foo.note
      rescue NameError => e
        puts "class: \#{e.class}"
      end
      module Bar
        def self.x = C4
      end
      begin
        Bar.x
      rescue NameError => e
        puts "module: \#{e.class}"
      end
      puts "foo bg: \#{Foo.new.bg}"
      puts "object: \#{Object.new.respond_to?(:seq)}"
      puts "note: \#{Ab3.number} \#{Object.const_defined?(:C4)}"

      # Commands added later are forwarded
      module MB::Sound::LaterMethods
        def later_command(x, y: 2) = x + y
      end
      MB::Sound.extend(MB::Sound::LaterMethods)
      puts "later: \#{later_command(1, y: 3)} \#{respond_to?(:later_command)}"
    RUBY

    expect(status).to be_success, out
    expect(out).to include('[MB::Sound::Note, true, "MB::Sound::Session", true, false]')
    expect(out).to include('class: NameError', 'module: NameError', 'foo bg: mine', 'object: false')
    expect(out).to include('later: 4 true', 'note: 56 false')
    # The 0.25 s part and its quiet second (QuietRun::QUIET_SECONDS)
    # played before the program ended
    expect(Integer(out[/frames (\d+)/, 1])).to be >= 1.25 * 48000
  end

  it "doesn't wait again after an explicit wait, and ends right away on an exception" do
    out, status = run_song(<<~RUBY)
      require 'mb-sound/dsl'

      MB::Sound::DSL::ExitWait.singleton_class.prepend(Module.new {
        def close = super.tap { |w| puts "exit wait \#{w}" }
      })

      bg :tone, 220.hz.saw.at(-20.db).until(0.05)
      wait
      puts "waited"
    RUBY
    expect(status).to be_success, out
    expect(out).to include("waited\nexit wait false")

    t = MB::U.clock_now
    out, status = run_song(<<~RUBY)
      require 'mb/sound/dsl'
      bg :tone, 220.hz.saw.at(-20.db)
      raise 'oops'
    RUBY
    expect(status).not_to be_success
    expect(out).to include('oops')
    expect(MB::U.clock_now - t).to be < 30 # (a forever tone: the wait would never end)
  end

  it 'runs a script helper at the top level' do
    out, status = run_song(<<~RUBY, name: 'helper_song.rb', args: %w[-o out.flac])
      require 'mb/sound/dsl'

      song_script(bars: 1) do |p|
        bpm 140
        track :bass, seq(A1, R, C2, E2).n8.loop do |clip|
          clip.synth(voices: 1) { |v| v.hz.saw.lp4(900) * v.amp_env }
        end
        scene :a, bass: :on
        flow { a 1 }
        start
      end
    RUBY
    expect(status).to be_success, out
    data = MB::Sound.read(File.join(File.dirname(tmp_path('helper_song.rb')), 'out.flac'))
    expect(data[0].abs.max).to be > 0.01
  end
end
