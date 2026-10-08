RSpec.describe(MB::Sound::ScriptRunner) do
  def runner(kind, argv, **params)
    described_class.new(kind, params, argv: argv.dup, script: 'bin/example.rb')
  end

  describe 'parameters' do
    it 'uses defaults and --name options' do
      r = runner(:effect, [], delay: 0.25, feedback: [0.5, 'Feedback gain'], mode: :sine, wet: true)
      expect(r.params.to_h).to eq(delay: 0.25, feedback: 0.5, mode: :sine, wet: true)

      r = runner(:effect, ['--feedback', '0.7', '--mode', 'ramp', '--no-wet'], delay: 0.25, feedback: 0.5, mode: :sine, wet: true)
      expect([r.params.delay, r.params.feedback, r.params.mode, r.params.wet]).to eq([0.25, 0.7, :ramp, false])

      r = runner(:effect, ['--delay', '0.1', '--feedback', '-0.3'], delay: 0.25, feedback: 0.5)
      expect(r.params.to_h).to eq(delay: 0.1, feedback: -0.3)
      expect(r.params[:delay]).to eq(0.1)
    end

    it 'converts underscores to dashes and keeps Integer types' do
      r = runner(:effect, ['--tap-count', '3'], tap_count: 2)
      expect(r.params.tap_count).to eq(3)
    end

    it 'rejects bare numbers and unknown arguments, suggesting options' do
      expect { runner(:effect, ['0.3'], delay: 0.25) }.to raise_error(described_class::UsageError, /Unexpected argument "0.3".*--delay 0.3/)
      expect { runner(:song, ['bogus']) }.to raise_error(described_class::UsageError, /Unexpected argument/)
      expect { runner(:effect, ['--bogus']) }.to raise_error(described_class::UsageError, /invalid option: --bogus/) { |e| expect(e.help).to include('--output FILE') }
    end

    it 'accepts short options, types, and allowed values after the default' do
      params = {
        count: [2, 'Repeats', 2.., '-n'],
        wave: [:sine, 'Waveform', [:sine, :ramp]],
        preset: [nil, Symbol, 'Preset'],
        time: [nil, 'Seconds or a range', ->(s) { s.include?('..') ? Range.new(*s.split('..').map { Float(_1) }) : Float(s) }],
      }
      r = runner(:effect, ['-n', '4', '--wave', 'ramp', '--preset', 'hall', '--time', '0.1..0.5'], **params)
      expect(r.params.to_h).to eq(count: 4, wave: :ramp, preset: :hall, time: 0.1..0.5)
      expect(runner(:effect, [], **params).params.to_h).to eq(count: 2, wave: :sine, preset: nil, time: nil)

      expect { runner(:effect, ['-n', '1'], **params) }.to raise_error(described_class::UsageError, /--count must be in 2\.\. \(got 1\)/)
      expect { runner(:effect, ['--wave', 'square'], **params) }.to raise_error(described_class::UsageError, /--wave must be one of sine, ramp/)
      expect { runner(:effect, ['--count', 'many'], **params) }.to raise_error(described_class::UsageError, /Invalid value for --count: "many"/)
      expect { runner(:effect, ['--time', 'x..y'], **params) }.to raise_error(described_class::UsageError, /Invalid value for --time/)
    end

    it 'shows short options, allowed values, and defaults in the help' do
      help = runner(:effect, [], count: [2, 'Repeats', 2.., '-n'], preset: [nil, Symbol, 'Preset']).instance_variable_get(:@parser).to_s
      expect(help).to match(/-n, --count VALUE\s+Repeats \(in 2\.\.\) \(default 2\)/)
      expect(help).to match(/--preset VALUE\s+Preset$/)
    end

    it 'rejects short options used by the common options' do
      expect { runner(:effect, [], wet: [1.0, '-c']) }.to raise_error(ArgumentError, /can't use -c/)
      expect { runner(:song, [], bpm: [120, '-b']) }.to raise_error(ArgumentError, /can't use -b/)
      expect(runner(:synth, [], bpm: [120, '-b']).params.bpm).to eq(120)
      expect { runner(:effect, [], wet: [1.0, :bogus]) }.to raise_error(ArgumentError, /Unknown :bogus/)
    end
  end

  describe 'latency profiles' do
    around(:each) do |ex|
      saved = ENV.delete('AUDIO_PROFILE')
      ex.run
    ensure
      saved ? ENV['AUDIO_PROFILE'] = saved : ENV.delete('AUDIO_PROFILE')
    end

    def with_profile(kind, argv, profile)
      described_class.new(kind, {}, argv: argv.dup, script: 'bin/example.rb', profile: profile)
    end

    it 'sets AUDIO_PROFILE from -L/--latency-profile' do
      runner(:synth, ['-L', 'low'])
      expect(ENV['AUDIO_PROFILE']).to eq('low')
      runner(:effect, ['--latency-profile', 'video'])
      expect(ENV['AUDIO_PROFILE']).to eq('video')
    end

    it "uses the script's profile when nothing else sets one" do
      with_profile(:song, [], :low)
      expect(ENV['AUDIO_PROFILE']).to eq('low')
    end

    it 'lets AUDIO_PROFILE override the script, and -L override both' do
      ENV['AUDIO_PROFILE'] = 'safe'
      with_profile(:song, [], :low)
      expect(ENV['AUDIO_PROFILE']).to eq('safe')

      with_profile(:song, ['-L', 'video'], :low)
      expect(ENV['AUDIO_PROFILE']).to eq('video')
    end

    it 'leaves AUDIO_PROFILE alone without a profile' do
      runner(:song, [])
      expect(ENV['AUDIO_PROFILE']).to be_nil
    end

    it 'rejects unknown profiles' do
      expect { runner(:synth, ['-L', 'fast']) }.to raise_error(described_class::UsageError, /invalid argument: -L fast/)
    end

    it 'is not an option of general scripts' do
      expect { runner(:script, ['-L', 'low']) }.to raise_error(described_class::UsageError, /invalid option: -L/)
    end
  end

  describe 'general scripts' do
    it 'passes positional arguments and parameters to the block' do
      r = runner(:script, ['a.flac', '--count', '3', 'b.txt'], count: 1)
      expect(r.run_script { |args, p| [args, p.count] }).to eq([['a.flac', 'b.txt'], 3])
    end

    it 'checks the number of positional arguments' do
      make = ->(argv, args) { described_class.new(:script, {}, argv: argv, script: 'bin/example.rb', args: args) }
      expect(make.(['a'], 1).args).to eq(['a'])
      expect { make.([], 1) }.to raise_error(described_class::UsageError, /Expected 1 argument \(got 0\)/)
      expect { make.(['a', 'b', 'c'], 1..2) }.to raise_error(described_class::UsageError, /Expected 1 to 2 arguments \(got 3\)/)
      expect { make.([], 1..) }.to raise_error(described_class::UsageError, /Expected at least 1 argument/)
      expect(make.(%w[a b c d], 1..).args.length).to eq(4)
    end

    it 'passes negative numbers through as positional arguments' do
      r = runner(:script, ['in.flac', '0', '100', '1', '-100', '--gain', '-12', '-g', '-3.5'], gain: [0.0, '-g'])
      expect(r.args).to eq(['in.flac', '0', '100', '1', '-100'])
      expect(r.params.gain).to eq(-3.5)
    end

    it 'removes options from argv, leaving positional arguments' do
      argv = ['a.flac', '--count', '3', '-100']
      described_class.new(:script, { count: 1 }, argv: argv, script: 'bin/example.rb')
      expect(argv).to eq(['a.flac', '-100'])
    end

    it 'requires parameters marked :required' do
      params = { start: [nil, Float, :required, 'Loop start'], xfade: 0.1 }
      expect(runner(:script, ['--start', '1.5'], **params).params.to_h).to eq(start: 1.5, xfade: 0.1)
      expect { runner(:script, [], **params) }.to raise_error(described_class::UsageError, /Missing --start/) { |e|
        expect(e.help).to match(/--start VALUE\s+Loop start \(required\)/)
      }
    end

    it 'only has --help among the common options' do
      help = runner(:script, [], wet: [1.0, '-w']).instance_variable_get(:@parser).to_s
      expect(help).to include('--help', '-w, --wet')
      expect(help).not_to include('--output', '--plot', '--quiet')
      expect { runner(:script, ['-q']) }.to raise_error(described_class::UsageError, /invalid option: -q/)
    end
  end

  describe 'Values#midi_cc' do
    it 'is a named constant at the parameter value when writing a file' do
      r = runner(:effect, ['in.flac', 'out.flac', '-q'], hz: 0.7)
      r.params.midi_source = r.method(:midi)
      expect(MB::Sound).not_to receive(:midi)
      node = r.params.midi_cc(1, :hz, range: 0.0..6.0)
      expect(node.graph_node_name).to eq('hz')
      expect(node.sample(4).to_a).to all(be_within(1e-6).of(0.7))
    end

    it 'gives MIDI a range relative to the parameter value unless relative: false' do
      r = runner(:effect, [], hz: 0.5)
      midi = double('Notes')
      r.params.midi_source = -> { midi }
      expect(midi).to receive(:control).with(have_attributes(number: 1, range: 0.0..3.0, center: 0.5, default: 64), smooth: nil).and_return(0.5.constant)
      expect(midi).to receive(:control).with(have_attributes(number: 2, range: 0.0..6.0, center: 0.5, default: 64), smooth: nil).and_return(0.5.constant)
      r.params.midi_cc(1, :hz, range: 0.0..6.0)
      r.params.midi_cc(2, :hz, range: 0.0..6.0, relative: false)
    end

    it 'is a Notes controller with the parameter as ControlSpec metadata, starting at the value' do
      ev = MB::Sound::MIDI::Event
      r = runner(:effect, [], hz: [0.5, 'LFO rate in Hz'], dry: [0.8, 'Dry level'])
      notes = MB::Sound::Notes.new(MIDIListSource.new(
        ev.cc(1, 127, time: Rational(100, 48000)), ev.cc(1, 0, time: Rational(200, 48000)), ev.cc(99, 0, time: 10r)
      ))
      r.params.midi_source = -> { notes }

      # Exact steps on the event samples (controllers glide 10 ms by default)
      hz = r.params.midi_cc(1, :hz, range: 0.0..6.0, smooth: false)
      dry = r.params.midi_cc(1, :dry, range: 1.0..0.0, smooth: false)
      expect(hz).to be_a(MB::Sound::Notes::Control)
      expect(hz.graph_node_name).to eq('hz')
      expect(r.params.midi).to equal(notes)

      expect(hz.spec).to have_attributes(number: 1, name: 'hz', description: 'LFO rate in Hz', range: 0.0..3.0, center: 0.5, default: 64)
      expect(dry.spec).to have_attributes(name: 'dry', description: 'Dry level', range: 0.8..0.0, center: nil, default: 0)
      expect(notes.controls.map(&:name)).to contain_exactly('hz', 'dry')

      h = hz.sample(300).dup
      d = dry.sample(300).dup
      expect(h[0]).to be_within(1e-6).of(0.5) # the parameter value until the knob moves
      expect(h[150]).to be_within(1e-6).of(3.0)
      expect(h[250]).to eq(0)
      expect(d[0]).to be_within(1e-6).of(0.8)
      expect(d[150]).to eq(0)
      expect(d[250]).to be_within(1e-6).of(0.8)
    end

    it 'maps the knob linearly on each side of the value' do
      spec = described_class::Values.cc_spec(1, :hz, 0.5, 0.0..3.0)
      expect(spec.value(64)).to eq(0.5)
      expect(spec.value(32)).to be_within(1e-9).of(0.25)
      expect(spec.value(127)).to eq(3.0)
      expect(described_class::Values.cc_spec(1, :x, 4.0, 0.0..2.0).default).to eq(127) # outside: nearest end
      expect(described_class::Values.cc_spec(1, :x, 1.0, 1.0..1.0).value(100)).to eq(1)
    end

    it 'is a constant when MIDI is not available' do
      r = runner(:effect, [], hz: 0.7)
      r.params.midi_source = r.method(:midi)
      allow(MB::Sound).to receive(:midi).and_raise(RuntimeError, 'Failed to open JACK client')
      expect { r.params.midi_cc(1, :hz, range: 0.0..6.0) }.to output(/MIDI control disabled \(Failed to open JACK client\)/).to_stdout
      expect(r.params.midi_cc(2, :hz, range: 0.0..6.0).sample(2).to_a).to all(be_within(1e-6).of(0.7))
    end
  end

  describe 'files and options' do
    it 'takes effect input and output files in order' do
      r = runner(:effect, ['in.flac', 'out.wav', '-f'])
      expect(r.options).to include(input: 'in.flac', output: 'out.wav', force: true)
    end

    it 'takes a synth MIDI input and an audio output' do
      r = runner(:synth, ['song.mid', 'out.flac', '--graphviz'])
      expect(r.options).to include(input: 'song.mid', output: 'out.flac', graphviz: true)
    end

    it 'takes effect input channels and --repeat' do
      expect(runner(:effect, ['-c', '1', '--repeat']).options).to include(channels: 1, repeat: -1)
      expect(runner(:effect, ['--input-channels', '3', '--repeat', '2']).options).to include(channels: 3, repeat: 2)
    end

    it 'takes a song output file and --overwrite' do
      r = runner(:song, ['song.flac', '--overwrite', '-q'])
      expect(r.options).to include(output: 'song.flac', force: true, quiet: true)
    end
  end

  describe '#run_effect' do
    let(:infile) { tmp_path('script_runner_in.flac') }
    let(:outfile) { tmp_path('script_runner_out.flac') }

    before do
      MB::Sound.write(infile, [Numo::SFloat.ones(4800) * 0.5, Numo::SFloat.ones(4800) * 0.25], sample_rate: 48000, overwrite: true)
    end

    it 'renders a file through the effect and lets it ring out' do
      r = runner(:effect, [infile, outfile, '-q'], delay: 0.2)
      expect { r.run_effect { |input, p| input.delay(p.delay, dry: 1, wet: 1, smoothing: false) } }.to output(/Rendered/).to_stdout

      l, rt = MB::Sound.read(outfile)
      expect(l.length / 48000.0).to be_within(0.05).of(0.1 + 0.2 + 1) # input, delay tail, then a second of quiet
      expect(l[2400]).to be_within(0.01).of(0.5) # effects run at unity master gain
      expect(rt[2400]).to be_within(0.01).of(0.25) # channels stay separate
      expect(l[(0.25 * 48000).round]).to be_within(0.01).of(0.5) # the delayed copy after the input ended
      expect(MB::Sound.master_gain).to eq(1)
    end
  end

  describe '#run_synth' do
    let(:outfile) { tmp_path('script_runner_synth.flac') }

    it 'gives the block a Notes playing the MIDI file, which makes synths and mono voices' do
      midi_file = 'spec/test_data/c2_sustain.mid'
      music_end = MB::Sound::MIDI::MIDIFile.new(midi_file).music_end
      seen = nil

      r = runner(:synth, [midi_file, outfile, '-q'], cutoff: 800)
      expect {
        r.run_synth { |midi, p|
          seen = midi
          midi.synth(voices: 2) { |v| v.hz.saw.filter(:lowpass, cutoff: v.cutoff(p.cutoff)) * v.amp_env(0.01, 0.1, 0.5, 0.2) }
        }
      }.to output(/Rendered/).to_stdout
      expect(seen).to be_a(MB::Sound::Notes)
      expect(seen.stream.source).to be_a(MB::Sound::MIDI::FileSource)

      # The synth (sustain pedal on) rings past the file's end, then stops
      # after a second below Session's -90 dB quiet threshold
      quiet = MB::Sound::Session::TAIL_THRESHOLD
      data = MB::Sound.read(outfile)[0]
      last_sound = (0...data.length).select { |i| data[i].abs >= quiet }.last / 48000.0
      expect(last_sound).to be > music_end
      expect(data.length / 48000.0 - last_sound).to be_within(0.1).of(1)

      # A mono voice applies the sustain pedal too: the pedal lifts at the
      # file's end (0.6875 s), after the note-off at 0.5 s, and the voice
      # ends with its release, when its nodes return nil
      mono = tmp_path('mono.flac')
      r = runner(:synth, [midi_file, mono, '-q'])
      expect { r.run_synth { |midi| midi.hz.saw * midi.amp_env(0.01, 0.1, 0.5, 0.2) } }.to output(/Rendered/).to_stdout
      data = MB::Sound.read(mono)[0]
      last_sound = (0...data.length).select { |i| data[i].abs >= quiet }.last / 48000.0
      expect(last_sound).to be_within(0.03).of(music_end + 0.2)
      expect(data.length / 48000.0 - last_sound).to be < 0.1

      # Without the pedal (Notes.new(..., sustain: false)), the note-off
      # releases it
      dry = tmp_path('dry.flac')
      r = runner(:synth, [midi_file, dry, '-q'])
      expect {
        r.run_synth { |midi| m = MB::Sound::Notes.new(midi.stream, sustain: false); m.hz.saw * m.amp_env(0.01, 0.1, 0.5, 0.2) }
      }.to output(/Rendered/).to_stdout
      data = MB::Sound.read(dry)[0]
      last_sound = (0...data.length).select { |i| data[i].abs >= quiet }.last / 48000.0
      expect(last_sound).to be_within(0.03).of(0.5 + 0.2)
    end

    it 'uses the synth MIDI for p.midi_cc' do
      r = runner(:synth, ['spec/test_data/c2_sustain.mid', outfile, '-q'], cutoff: 800)
      node = nil
      expect { r.run_synth { |midi, p| node = p.midi_cc(74, :cutoff, range: 0.5..2.0); midi.hz.saw * midi.amp_env * 0 } }.to output(/Rendered/).to_stdout
      expect(node).to be_a(MB::Sound::Notes::Control)
      expect(node.spec).to have_attributes(number: 74, name: 'cutoff', center: 800)
    end

    it 'refuses a MIDI input file that is not MIDI' do
      r = runner(:synth, ['spec/test_data/arp_a7.flac', '-i', 'spec/test_data/arp_a7.flac', '-q'])
      expect { r.run_synth { |midi| midi.gate } }.to raise_error(ArgumentError, /not a MIDI file/)
    end

    it 'renders a MIDI file, letting notes ring out and stopping after a second of quiet' do
      midi_file = 'spec/test_data/c2_sustain.mid'
      music_end = MB::Sound::MIDI::MIDIFile.new(midi_file).music_end

      r = runner(:synth, [midi_file, outfile, '-q'])
      expect { r.run_synth { |input| MB::Sound.synth(input) { |midi| midi.hz * midi.env } } }.to output(/Rendered/).to_stdout

      data = MB::Sound.read(outfile)[0]
      last_sound = (0...data.length).select { |i| data[i].abs > 1e-4 }.last / 48000.0

      expect(last_sound).to be > music_end # the release rings past the last MIDI event
      expect(data.length / 48000.0 - last_sound).to be_within(0.1).of(1) # a second of quiet (it was 5 s after the last event)
    end
  end

  describe 'MIDI controls' do
    let(:outfile) { tmp_path('script_runner_controls.flac') }
    let(:xmlfile) { tmp_path('controls.xml') }

    def synth_block
      ->(midi, p) {
        cutoff = p.midi_cc(21, :cutoff, range: 0.5..2.0)
        midi.synth(voices: 2) { |v| v.hz.saw.filter(:lowpass, cutoff: cutoff * v.cutoff(1)) * v.amp_env(0.01, 0.1, 0.5, 0.2) }
      }
    end

    it "lists a synth's controls with its parameters, and writes ACID XML" do
      r = runner(:synth, ['spec/test_data/c2_sustain.mid', outfile, '--acid-xml', xmlfile], cutoff: [800, 'Filter cutoff'])
      expect { r.run_synth(&synth_block) }.to output(
        a_string_including(
          'MIDI controls:',
          'CC  21 cutoff (400.0..1600, default 64) - Filter cutoff',
          'CC  64 Sustain',
          'CC  74 Brightness',
          "MIDI controls) to #{xmlfile}",
          'Rendered'
        )
      ).to_stdout

      xml = File.read(xmlfile)
      expect(xml).to start_with('<?xml')
      expect(xml).to include('mapname="example.rb"', '<param name="cutoff">', '<param name="Sustain">', '<param name="Brightness">')
    end

    it 'prints nothing about controls with -q, but still writes the XML' do
      r = runner(:synth, ['spec/test_data/c_major.mid', '-q', '--acid-xml', xmlfile], cutoff: 800)
      graph = synth_block.call(r.instance_variable_set(:@synth_notes, MB::Sound::Notes.new('spec/test_data/c_major.mid')), r.params)
      expect { r.send(:announce, graph) }.not_to output.to_stdout
      expect(File.read(xmlfile)).to include('<param name="cutoff">')
    end

    it "prints the XML with --acid-xml -" do
      r = runner(:synth, ['spec/test_data/c_major.mid', '-q', '--acid-xml', '-'], cutoff: 800)
      r.instance_variable_set(:@synth_notes, MB::Sound::Notes.new('spec/test_data/c_major.mid'))
      graph = r.instance_variable_get(:@synth_notes).synth(voices: 1) { |v| v.hz.saw * v.mod }
      expect { r.send(:announce, graph) }.to output(/parammap.*Modulation.*Sustain/m).to_stdout
    end

    it "doesn't list an effect's controls without MIDI, but writes them as XML" do
      r = runner(:effect, ['in.flac', 'out.flac', '--acid-xml', xmlfile], hz: [0.5, 'LFO rate'])
      r.params.midi_source = r.method(:midi)
      graph = 100.hz.sine * r.params.midi_cc(1, :hz, range: 0.0..2.0)
      expect { r.send(:announce, graph) }.not_to output(/MIDI controls:/).to_stdout
      expect(File.read(xmlfile)).to include('<param name="hz">', '<ccMsg>1</ccMsg>', '<Neutral>64</Neutral>')
    end

    it "lists an effect's controls when MIDI is open" do
      r = runner(:effect, ['in.flac', 'out.flac', '-m', 'spec/test_data/mod_wheel.mid'], hz: [0.5, 'LFO rate'])
      r.params.midi_source = r.method(:midi)
      graph = nil
      expect { graph = 100.hz.sine * r.params.midi_cc(1, :hz, range: 0.0..2.0) }.to output(/MIDI control from/).to_stdout
      expect { r.send(:announce, graph) }.to output(/MIDI controls:\n  CC   1 hz \(0.0..1.0, default 64\) - LFO rate\n\z/).to_stdout
    end

    it 'has --acid-xml for effects and synths only' do
      expect(runner(:effect, []).instance_variable_get(:@parser).to_s).to include('--acid-xml FILE')
      expect(runner(:synth, []).instance_variable_get(:@parser).to_s).to include('--acid-xml FILE')
      expect { runner(:song, ['--acid-xml', 'x.xml']) }.to raise_error(described_class::UsageError)
    end
  end

  describe '#ending_nodes' do
    it 'keeps a Synth but skips the nodes inside it and gated envelopes' do
      r = runner(:synth, [])
      gated = MB::Sound::Envelope.new(gate: 0.constant)
      one_shot = MB::Sound::Envelope.new
      synth = MB::Sound::Synth.new('spec/test_data/c_major.mid', voices: 2) { |v| v.hz.saw * v.amp_env }
      graph = (synth + 220.hz.sine * gated + 110.hz.sine * one_shot).ringdown

      nodes = r.send(:ending_nodes, graph)
      expect(nodes).to include(synth, one_shot, graph)
      expect(nodes).not_to include(gated)
      expect(nodes.grep(MB::Sound::Notes::Node)).to eq([])
      expect(nodes.grep(MB::Sound::Envelope)).to eq([one_shot])
    end
  end

  describe '#run_song' do
    let(:outfile) { tmp_path('script_runner_song.flac') }

    it 'draws the graph at the start of the song with --graphviz, then renders' do
      dot = nil
      allow_any_instance_of(MB::Sound::Session::GraphView::Box).to receive(:open_graphviz) { |box| dot = box.graphviz; 'song.png' }

      r = runner(:song, [outfile, '-q', '--graphviz'])
      song = -> {
        MB::Sound.bg(:tone, 220.hz.sine.at(0.5).named('song tone'))
        MB::Sound.master { |mix| mix.softclip }
      }
      expect { r.run_song(bars: 1) { song.call } }.to output(/Wrote GraphViz image to song.png.*Rendered/m).to_stdout

      expect(dot).to include('song tone', 'softclip ×2', 'label="tone"', 'label="master input"')
      expect(MB::Sound.read(outfile)[0].abs.max).to be > 0.1
    end

    it 'plays at the --bpm tempo, scaling the song tempo changes' do
      seen = []
      r = runner(:song, [outfile, '-q', '--bpm', '60'])
      expect {
        r.run_song(bars: 3) {
          MB::Sound.bpm 120
          MB::Sound.bg(:tone, 220.hz.sine.at(0.5), fade: 0)
          MB::Sound.at_bar(2) { MB::Sound.bpm 90 }
          MB::Sound.at_bar(3) { seen << MB::Sound.transport.bpm }
        }
      }.to output(/Rendered/).to_stdout

      expect(seen).to eq([45.0])
      expect(MB::Sound.read(outfile)[0].length / 48000.0).to be_within(0.05).of(4 + 16 / 3.0 * 2)
    end

    context 'when playing live' do
      before(:each) do
        ENV['OUTPUT_TYPE'] = 'null'
      end

      after(:each) do
        MB::Sound::Session.default.close
        MB::Sound.rewind
        ENV.delete('OUTPUT_TYPE')
      end

      it 'stops an endless song after --bars, cancelling later schedules' do
        later = false
        r = runner(:song, ['-q', '--bars', '0.25']) # half a second at 120 BPM
        t = MB::U.clock_now
        r.run_song {
          MB::Sound.bpm 120
          MB::Sound.bg(:tone, 220.hz.sine, fade: 0)
          MB::Sound.at_bar(2) { later = true }
        }

        expect(MB::U.clock_now - t).to be_between(0.4, 3)
        expect(MB::Sound.scheduled).to be_empty
        expect(later).to eq(false)
      end
    end
  end
end
