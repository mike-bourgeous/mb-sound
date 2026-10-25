RSpec.describe('bin/ script shebangs') do
  # Ruby's default 100 ms thread time slice lets any busy Ruby thread starve
  # the audio writer for longer than the sound card queue (measured with
  # bin/audio_check.rb --busy: 131 underruns in 10 s on macOS by default, 0
  # with 10 ms).  The variable is read when Ruby starts, so scripts set it
  # in the shebang (env -S works on Linux and macOS).  The shebang also asks
  # mb-sound to turn on YJIT, Ruby's JIT compiler (about a third less graph
  # cost per buffer after a short warm-up; see MB::Sound.warm_up), with
  # mb-sound's call threshold (MB::Sound::JIT): RUBY_YJIT_ENABLE=1 would
  # start YJIT at boot, after which the threshold can't change.
  SHEBANG = "#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby\n"
  def lib = File.expand_path('../../lib', __dir__)

  def run_with_shebang(name, code)
    path = tmp_path(name)
    File.write(path, SHEBANG + code)
    File.chmod(0o755, path)
    `#{path}`.strip
  end

  it 'sets a 10 ms thread time slice and asks for YJIT in every script' do
    scripts = Dir['bin/**/*.rb']
    expect(scripts.length).to be > 50

    wrong = scripts.reject { |f| File.open(f, &:gets) == SHEBANG }
    expect(wrong).to be_empty, "Scripts without #{SHEBANG.strip}:\n#{wrong.join("\n")}"
  end

  it 'passes the time slice to Ruby' do
    expect(run_with_shebang('shebang_check.rb', 'puts ENV.fetch("RUBY_THREAD_TIMESLICE", "unset")')).to eq('10')
  end

  it 'starts Ruby without YJIT and enables it when mb-sound loads, at mb-sound\'s threshold' do
    code = <<~RUBY
      before = RubyVM::YJIT.enabled?
      $LOAD_PATH.unshift(#{lib.inspect})
      require 'mb/sound/jit'
      puts [before, RubyVM::YJIT.enabled?, MB::Sound::JIT.threshold].inspect
    RUBY
    expect(run_with_shebang('shebang_yjit.rb', code)).to eq([false, true, MB::Sound::JIT::CALL_THRESHOLD].inspect)
  end

  describe 'MB::Sound::JIT' do
    # Runs +code+ after loading mb/sound/jit with +env+, in a Ruby without
    # YJIT at boot but with its compile log configured, so the child sees
    # when a method compiled.
    def child(env, code)
      script = "$LOAD_PATH.unshift(#{lib.inspect}); require 'mb/sound/jit'; #{code}"
      env = { 'RUBY_YJIT_ENABLE' => nil, 'RUBYOPT' => nil }.merge(env)
      IO.popen(env, [RbConfig.ruby, '--yjit-disable', '--yjit-log=quiet', '-e', script], err: [:child, :out], &:read).strip
    end

    # Counts the calls of a new method until YJIT's log shows it compiled.
    let(:calls) { <<~RUBY }
      def target_fn(x) = x
      n = 0
      while n < 200
        target_fn(1)
        n += 1
        break if (RubyVM::YJIT.log || []).any? { |_, name| name.to_s.include?('target_fn') }
      end
      puts n
    RUBY

    it 'compiles methods after CALL_THRESHOLD calls' do
      expect(child({ 'MB_SOUND_YJIT' => '1' }, calls)).to eq(MB::Sound::JIT::CALL_THRESHOLD.to_s)
    end

    it 'takes another threshold from MB_SOUND_YJIT_CALL_THRESHOLD' do
      expect(child({ 'MB_SOUND_YJIT' => '1', 'MB_SOUND_YJIT_CALL_THRESHOLD' => '7' }, calls)).to eq('7')
    end

    it 'leaves YJIT off without MB_SOUND_YJIT' do
      expect(child({ 'MB_SOUND_YJIT' => nil }, 'puts [RubyVM::YJIT.enabled?, MB::Sound::JIT.threshold].inspect')).to eq('[false, nil]')
      expect(child({ 'MB_SOUND_YJIT' => '0' }, 'puts RubyVM::YJIT.enabled?')).to eq('false')
    end

    it 'refuses a threshold below 1' do
      expect(child({ 'MB_SOUND_YJIT' => '1', 'MB_SOUND_YJIT_CALL_THRESHOLD' => '0' }, '')).to include('must be at least 1')
    end

    it 'does nothing in a process without the variable (specs)' do
      expect(MB::Sound::JIT.enable_from_env({})).to be_nil
    end
  end
end
