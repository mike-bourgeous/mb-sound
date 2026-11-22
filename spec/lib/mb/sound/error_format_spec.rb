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

    # (ux-friction-3: before asking how to clear everything he tried
    # clear, reset, session.clear, clear :form, Session.clear, "a few
    # others")
    it 'points the guesses at emptying the set to clear_set' do
      want = 'did you mean clear_set (stops everything and takes out the tracks, scenes, flow, knobs, buses, and racks; tempo, key, and master gain stay; undo puts it back)'
      %w[reset clear_session clear_all new_set reset_set start_over Session.clear Session.current.clear Session.current.reset].each do |code|
        e = (MB::Sound.module_eval(code) rescue $!)
        expect(described_class.summary(e)).to include(want), "#{code}: #{described_class.summary(e)}"
      end
      expect(described_class.summary((MB::Sound.module_eval('reset') rescue $!))).to include("or pry-reset (Pry's reset of the console itself)")
      %w[session.clear session.reset].each do |code|
        e = (MB::Sound.module_eval(code) rescue $!)
        expect(described_class.summary(e)).to eq("NameError: undefined local variable or method 'session' (did you mean Session.current (the console's session; " \
                                                 'clear_set empties its set: stops everything and takes out the tracks, scenes, flow, knobs, buses, and racks; ' \
                                                 'tempo, key, and master gain stay; undo puts it back)?)'), code
      end
    end

    it 'clears the screen with clear, saying once what empties the set, and points clear :form at the commands that clear parts' do
      MB::Sound::Internal.instance_variable_set(:@clear_told, nil)
      expect { MB::Sound::Internal.console_clear }.to output("\e[H\e[2J\e[2mclear clears the screen; clear_set empties the set (tracks, scenes, flow, knobs, buses, racks)\e[0m\n").to_stdout
      expect { MB::Sound::Internal.console_clear }.to output("\e[H\e[2J").to_stdout
      expect { MB::Sound::Internal.console_clear(:form) }.to raise_error(ArgumentError, /\Aclear clears the screen; :form goes to another command: clear_set empties the whole set .*untrack :name .*finish/)
      MB::Sound::Internal.instance_variable_set(:@clear_told, nil)
      expect { MB::Sound::Internal.console_clear(quiet: true) }.to output("\e[H\e[2J").to_stdout
    end

    it 'points a note for a track at meta notes:, about:, and ui.note (GUESSES)' do
      e = (MB::Sound.note(:lead, 'breathy') rescue $!)
      expect(e).to be_a(NoMethodError)
      expect(described_class.summary(e)).to eq("NoMethodError: undefined method 'note' (did you mean meta :lead, notes: '...' (kept with :lead, saved with the set), " \
                                               "about: '...' when you save a graph, or ui.note '...' (a note about what you hear, with the screen)?)")
    end

    it 'suggests what people meant by common method guesses on nodes (NODE_GUESSES)' do
      e = (220.hz.sine.delta rescue $!)
      expect(described_class.summary(e)).to include('did you mean derivative (the slope of a signal')
      e = (MB::Sound.stereo(1.constant, 2.constant).cumsum rescue $!)
      expect(described_class.summary(e)).to include('did you mean integral (the running sum')
      # (Kez, panel 3: transpose after .fm made a Tone; Ruby suggested "transients")
      e = (220.hz.fm(5.hz.at(2)).transpose(0.1) rescue $!)
      expect(described_class.summary(e)).to include('did you mean v.hz.transpose(7).fm(...) (transpose the pitch first')
      expect(described_class.summary(e)).not_to include('transients')
      # (a node that isn't a Tone keeps Ruby's suggestions)
      e = ((1.constant + 2).transpose(1) rescue $!)
      expect(described_class.summary(e)).not_to include('pitch first')
    end

    it "points the maintainer's echo and effect-chaining guesses at what exists (ux-friction-1)" do
      e = (1.constant.echo rescue $!)
      expect(described_class.summary(e)).to include('did you mean delay(0.375, feedback: 0.4) (an echo; also tape_echo, ping_pong')
      cab = MB::Sound::Library.index.lookup(:rotary, :cabinet)
      asym = MB::Sound::Library.index.lookup(:shape_db, :asymmetric)
      %i[| & + >>].each do |op|
        e = (cab.public_send(op, asym) rescue $!)
        expect(described_class.summary(e)).to include("did you mean fx :track, [#{cab.head_path}, #{asym.head_path}] (a list chains effects in order)"), op.inspect
      end
      expect { cab.then(asym) }.to raise_error(ArgumentError, /then takes a block, not an argument: fx :track, \[/)
      expect { cab.call(asym) }.to raise_error(ArgumentError, /call takes a signal, not #{Regexp.escape(asym.head_path)}: fx :track, \[/)
      expect(cab.then { |x| x.name }).to eq(:cabinet)
    end

    # followups-1: the maintainer's `fx :drums, L.fx.circle(mix: 0.5)` and
    # `L.fx.circle(dry: -3.db, wet: -6.db)` said "wrong number of arguments
    # (given 1, expected 2)"
    it 'says an effect entry takes the signal first, with its settings in the spellings that work' do
      circle = MB::Sound::Library.index.lookup(:phaser, :circle)
      expect { circle.call(mix: 0.5) }.to raise_error(ArgumentError,
        /\AL\.fx\.circle takes the signal first: sig\.then \{ L\.fx\.circle\.\(it, mix: 0\.5\) \}, or on a track fx :track, ->\(s\) \{ L\.fx\.circle\.\(s, mix: 0\.5\) \}.*sig\.blend\(0\.5\)/)
      expect { circle.call(dry: -3.db, wet: -6.db) }.to raise_error(ArgumentError, /L\.fx\.circle\.\(s, dry: -3\.db, wet: -6\.db\)/)
      # (the spellings it gives work)
      sig = 220.hz.saw
      expect(circle.(sig, mix: 0.5)).to be_a(MB::Sound::GraphNode)
      expect(sig.blend(0.5) { it.then(&circle) }).to be_a(MB::Sound::GraphNode)
    end

    # (the maintainer's take, 2026-11-21: `bg :drums, L.gen.beat.techno.transpose(4)`)
    it 'names .call for a clip method on a generator entry that was not called (ux-friction-2)' do
      gen = MB::Sound::L.gen.beat.techno
      e = (gen.transpose(4) rescue $!)
      expect(described_class.summary(e)).to include('did you mean L.gen.beat.techno.call.transpose(4) (a library generator gives its clip when called; L.gen.beat.techno(...) takes its params)?')
      e = (gen.echo(3, 1.n32, pitch: 10) rescue $!)
      expect(described_class.summary(e)).to include('L.gen.beat.techno.call.echo(3, 1.n32, pitch: 10)')
      e = (gen.frobnicate rescue $!)
      expect(described_class.summary(e)).not_to include('.call.')
      e = (MB::Sound::L.fx.reverb.hall.transpose(4) rescue $!)
      expect(described_class.summary(e)).not_to include('.call.')
    end

    it "points the maintainer's LFO, scale, and note guesses at what exists (ux-friction-1 round 2)" do
      lfo = 2.bars.lfo.ramp
      expect(described_class.summary((lfo.exp rescue $!))).to include('did you mean at(D3.number..B6.number).freq (an LFO swept in notes')
      expect(described_class.summary((lfo.at(150..2000).unipolar rescue $!))).to include('did you mean at(150..2000) (it maps the whole -1..1 swing')
      s = described_class.summary((0.2.hz.lfo.freerun rescue $!))
      expect(s).to include('did you mean freewheel (a bar-synced LFO running free of the timeline')
      expect(s).not_to match(/did you mean free\?/)
      expect(described_class.summary((MB::Sound.scale.phrygian rescue $!))).to include('did you mean scale(:phrygian) (a mode by name')
      expect(described_class.summary((MB::Sound::A2.minor rescue $!))).to include('did you mean scale(:minor, A2) (the mode first, then the root)')
      expect(described_class.summary((1.beat.ramp rescue $!))).to include('did you mean 1.beat.lfo.ramp (the shape comes after .lfo')
      expect(described_class.summary((MB::Sound::A2.nonsense_name rescue $!))).not_to include('scale(')
    end

    it 'prints a constant typed at the prompt as one line, not a backtrace (ux-friction-1 round 2: III)' do
      e = (MB::Sound.module_eval('III') rescue $!)
      expect(e).to be_a(NameError)
      expect(described_class.short?(e)).to eq(true)
      expect(described_class.console(e, color: false)).to start_with('NameError: uninitialized constant MB::Sound::III')
    end

    it "prints a typo on the ui facade as one line, and points ui.warn at the messages pane (ux-friction-1 round 2)" do
      e = (MB::Sound::UI.facade.frobnicate rescue $!)
      expect(described_class.short?(e)).to eq(true)
      expect(described_class.console(e, color: false)).to start_with("NoMethodError: undefined method 'frobnicate'")
      e = (MB::Sound::UI.facade.warn rescue $!)
      expect(described_class.console(e, color: false)).to include('did you mean ui.messages (the messages pane, NAV m')
    end

    it "answers the maintainer's unison and motifs guesses of his third take (ux-friction-1 round 2)" do
      sum = ->(&f) { described_class.summary((f.call rescue $!)) }
      expect(sum.() { 110.hz.unison(5, pan: 0..1) }).to eq('ArgumentError: unison: unknown keyword: :pan (did you mean spread:?)')
      expect(sum.() { 110.hz.unison(5, spread: 0..1) }).to include('(got 0..1); 1 is the widest, and an LFO moves it: spread: 4.bars.lfo.at(0..1)')
      expect(sum.() { 3.bar.lfo.at(5.cents..60.cents) }).to include('in semitones that is .at(0.05..0.6), as a detune node takes (1.cents is 0.01)')
      expect(sum.() { 3.bar.lfo.at(5..60) * 1.cents }).to include('an Interval is a pitch step, not a gain: multiply by its semitones')
      expect(sum.() { MB::Sound.motifs(MB::Sound.scale, length: 1.n8) }).to eq('ArgumentError: motifs: unknown keyword: :length (did you mean legato:?)')
      expect(sum.() { MB::Sound.motifs(MB::Sound.scale, answer: true) }).to include('like { b: :a } (the default; {} for none) (got true)')
      expect(sum.() { MB::Sound.scale(:phrygian, :a, range: MB::Sound::A1..MB::Sound::A4) }).to include(
        'scale takes a mode and a root, no keywords (got range: A1..A4): they belong to the call around it, e.g. motifs(scale(:phrygian, :a), range: A1..A4)'
      )
      expect(MB::Sound.motifs(MB::Sound.scale, answer: {})).to be_a(MB::Sound::Sequence::Clip)
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

  describe '.argument_help' do
    it 'suggests keywords for every recorded DSL method' do
      expect { 261.63.hz.saw.lp4(800, resonanse: 0.3) }.to raise_error(ArgumentError, /\Alp4: unknown keyword: :resonanse\nDid you mean\?  resonance:/)
      expect { 261.63.hz.saw.delay(0.1, feedbak: 0.3) }.to raise_error(ArgumentError, /delay: unknown keyword: :feedbak\nDid you mean\?  feedback:/)
      expect { 261.63.hz.saw.lp4(800, zzzzzz: 1) }.to raise_error(ArgumentError, /lp4: unknown keyword: :zzzzzz \(lp4 takes .*resonance:/)
    end

    it 'gives the signature for wrong arity (notes-fix-1)' do
      expect { 261.63.hz.saw.lp4 }.to raise_error(ArgumentError, /\Alp4: wrong number of arguments \(given 0, expected 1\); lp4\(cutoff, resonance: nil, .*tuning: :musical\)\z/)
      # (one line, though lp4's def spans two)
      expect(MB::Sound::ErrorFormat.summary((261.63.hz.saw.lp4 rescue $!))).not_to include("\n")
      clip = MB::Sound.seq(MB::Sound::C4).n8
      expect { clip.ratchet }.to raise_error(ArgumentError, /\Aratchet: wrong number of arguments \(given 0, expected 1\); ratchet\(count, rate: nil, velocity: nil\)\z/)
    end

    it 'leaves other ArgumentErrors alone' do
      expect { 261.63.hz.saw.lp4(800, mode: :zzz) }.to raise_error(ArgumentError) { |e| expect(e.message).not_to start_with('lp4: ') }
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

    it 'exits 2 with one line from a plain script (MB::Sound.script) when the sound card is missing' do
      out = `OUTPUT_TYPE=device OUTPUT_DEVICE=no-such-device-ux-fix-2 bin/play.rb spec/test_data/arp_a7.flac 2>&1`
      expect($?.exitstatus).to eq(2)
      expect(out).to start_with(%Q{play.rb: No output device matches "no-such-device-ux-fix-2".  Devices:\n})
      expect(out).not_to include('from ')
    end

    it 'exits 2 with one line from a real script' do
      out = `bin/effects/tape_delay.rb nosuch.flac -o #{tmp_path('x.flac')} 2>&1`
      expect($?.exitstatus).to eq(2)
      expect(out).to eq(%Q{tape_delay.rb: no file "nosuch.flac"\n})
    end
  end
end
