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
  end
end
