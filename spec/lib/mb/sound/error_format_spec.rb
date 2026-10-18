# ux-fix-1 (items 2, 6, 9, 11, 17): one color policy, one error format,
# one unknown-keyword wrapper over the DSL surface, quiet device errors.
RSpec.describe(MB::Sound::ErrorFormat) do
  describe MB::Sound::ColorPolicy do
    let(:tty) { StringIO.new.tap { |io| def io.tty? = true } }

    it 'colors only a terminal without NO_COLOR or TERM=dumb, unless FORCE_COLOR' do
      expect(described_class.color?(tty, env: {})).to eq(true)
      expect(described_class.color?(StringIO.new, env: {})).to eq(false)
      expect(described_class.color?(tty, env: { 'NO_COLOR' => '1' })).to eq(false)
      expect(described_class.color?(tty, env: { 'NO_COLOR' => '' })).to eq(true)
      expect(described_class.color?(tty, env: { 'TERM' => 'dumb' })).to eq(false)
      expect(described_class.color?(StringIO.new, env: { 'FORCE_COLOR' => '1' })).to eq(true)
      expect(described_class.color?(StringIO.new, env: { 'FORCE_COLOR' => '0' })).to eq(false)
    end

    it 'strips color codes written to an IO that may not be colored' do
      io = StringIO.new
      described_class.strip_output!([io])
      io.puts "\e[1;33mnow\e[0m bar"
      io.print "\e[2mdim\e[0m\n"
      expect(io.string).to eq("now bar\ndim\n")
    end

    it 'prints help pages and now plainly into a pipe' do
      expect(MB::Sound.help(:turn).to_s).not_to include("\e[")
      expect(MB::Sound.now.to_s).not_to include("\e[")
    end
  end

  describe '.summary' do
    it 'prints a console typo as one line with suggestions' do
      e = (MB::Sound.plya rescue $!)
      expect(described_class.summary(e)).to eq("NoMethodError: undefined method 'plya' (did you mean play?)")
      expect(described_class.short?(e)).to eq(true)
      expect(described_class.console(e, color: false)).to eq("NoMethodError: undefined method 'plya' (did you mean play?)")
    end

    it 'turns Did you mean blocks in messages into a parenthesis' do
      e = ArgumentError.new("no scene :dorp\nDid you mean?  :drop\n                :dorm")
      expect(described_class.summary(e)).to eq('ArgumentError: no scene :dorp (did you mean :drop, :dorm?)')
    end

    it 'keeps backtraces for likely bugs raised inside the library' do
      e = (MB::Sound::ErrorFormat.summary(nil) rescue $!) # a NoMethodError inside lib/
      expect(e).to be_a(NoMethodError)
      expect(described_class.short?(e)).to eq(false)
      expect(described_class.console(e, color: false)).to include('error_format.rb')
      expect(described_class.short?(ArgumentError.new('x').tap { |a| a.set_backtrace(e.backtrace) })).to eq(true)
    end
  end

  describe '.unknown_keyword' do
    it 'suggests keywords for every recorded DSL method' do
      expect { 261.63.hz.saw.lp4(800, resonanse: 0.3) }.to raise_error(ArgumentError, /\Alp4: unknown keyword: :resonanse\nDid you mean\?  resonance:/)
      expect { 261.63.hz.saw.delay(0.1, feedbak: 0.3) }.to raise_error(ArgumentError, /delay: unknown keyword: :feedbak\nDid you mean\?  feedback:/)
      expect { 261.63.hz.saw.lp4(800, zzzzzz: 1) }.to raise_error(ArgumentError, /lp4: unknown keyword: :zzzzzz \(lp4 takes .*resonance:/)
    end

    it 'leaves other ArgumentErrors alone' do
      expect { 261.63.hz.saw.lp4 }.to raise_error(ArgumentError, /wrong number of arguments/)
    end
  end

  describe 'no sound card' do
    it 'raises DeviceOutput::Unavailable with what to do, holding back C library noise' do
      expect {
        expect {
          MB::Sound::DeviceOutput.opening {
            STDERR.write("ALSA lib confmisc.c:855:(parse_card) cannot find card '0'\n")
            raise MB::Sound::FastAudio::Error, 'Could not open audio device: Failed to open backend device'
          }
        }.to raise_error(MB::Sound::DeviceOutput::Unavailable, /\ANo audio output device \(Failed to open backend device\).*OUTPUT_TYPE=null.*render/)
      }.not_to output.to_stderr_from_any_process
      expect(MB::Sound::DeviceOutput::Unavailable.ancestors).to include(MB::Sound::FastAudio::Error)
    end
  end

  describe 'script inputs' do
    def runner(kind, argv)
      MB::Sound::ScriptRunner.new(kind, {}, argv: argv.dup, script: 'bin/example.rb')
    end

    it 'refuses missing files and -o without an input before building' do
      expect { runner(:effect, ['nosuch.flac', '-o', 'x.flac']).send(:check_inputs) }.to raise_error(MB::Sound::ScriptRunner::InputError, 'no file "nosuch.flac"')
      expect { runner(:effect, ['-o', 'x.flac']).send(:check_inputs) }.to raise_error(MB::Sound::ScriptRunner::InputError, /give one/)
      expect { runner(:synth, ['-o', 'y.flac', 'nosuch.mid']).send(:check_inputs) }.to raise_error(MB::Sound::ScriptRunner::InputError, /no file "nosuch.mid"/)
      expect { runner(:synth, ['-o', 'y.flac', 'Keystation']).send(:check_inputs) }.not_to raise_error
    end

    it 'exits 2 with one line from a real script' do
      out = `bin/effects/tape_delay.rb nosuch.flac -o #{tmp_path('x.flac')} 2>&1`
      expect($?.exitstatus).to eq(2)
      expect(out).to eq(%Q{tape_delay.rb: no file "nosuch.flac"\n})
    end
  end
end
