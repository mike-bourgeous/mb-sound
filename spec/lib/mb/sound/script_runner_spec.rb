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
      midi = double('MidiDsl')
      r.params.midi_source = -> { midi }
      expect(midi).to receive(:cc).with(1, range: 0.0..3.0, default: 0.5).and_return(0.5.constant)
      expect(midi).to receive(:cc).with(2, range: 0.0..6.0, default: 0.5).and_return(0.5.constant)
      r.params.midi_cc(1, :hz, range: 0.0..6.0)
      r.params.midi_cc(2, :hz, range: 0.0..6.0, relative: false)
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
    let(:infile) { 'tmp/script_runner_in.flac' }
    let(:outfile) { 'tmp/script_runner_out.flac' }

    before do
      FileUtils.mkdir_p('tmp')
      MB::Sound.write(infile, [Numo::SFloat.ones(4800) * 0.5, Numo::SFloat.ones(4800) * 0.25], sample_rate: 48000, overwrite: true)
      File.unlink(outfile) if File.exist?(outfile)
    end

    it 'renders a file through the effect and lets it ring out' do
      r = runner(:effect, [infile, outfile, '-q'], delay: 0.2)
      expect { r.run_effect { |input, p| input.delay(p.delay, dry: 1, wet: 1, smoothing: false) } }.to output(/Rendered/).to_stdout

      l, rt = MB::Sound.read(outfile)
      expect(l.length / 48000.0).to be_within(0.05).of(0.1 + 0.2 + 1) # input, delay tail, then a second of quiet
      expect(l[2400]).to be_within(0.01).of(0.5)
      expect(rt[2400]).to be_within(0.01).of(0.25) # channels stay separate
      expect(l[(0.25 * 48000).round]).to be_within(0.01).of(0.5) # the delayed copy after the input ended
    end
  end

  describe '#run_song' do
    let(:outfile) { 'tmp/script_runner_song.flac' }

    before do
      FileUtils.mkdir_p('tmp')
      File.unlink(outfile) if File.exist?(outfile)
    end

    it 'draws the graph at the start of the song with --graphviz, then renders' do
      dot = nil
      allow_any_instance_of(MB::Sound::Session::GraphView::Box).to receive(:open_graphviz) { |box| dot = box.graphviz; 'song.png' }

      r = runner(:song, [outfile, '-q', '--graphviz'])
      song = -> {
        MB::Sound.bg(:tone, 220.hz.sine.at(0.5).forever.named('song tone'))
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
          MB::Sound.bg(:tone, 220.hz.sine.at(0.5).forever, fade: 0)
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
          MB::Sound.bg(:tone, 220.hz.sine.forever, fade: 0)
          MB::Sound.at_bar(2) { later = true }
        }

        expect(MB::U.clock_now - t).to be_between(0.4, 3)
        expect(MB::Sound.scheduled).to be_empty
        expect(later).to eq(false)
      end
    end
  end
end
