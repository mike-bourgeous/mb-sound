RSpec.describe(MB::Sound::PlaybackMethods) do
  before(:each) do
    ENV['OUTPUT_TYPE'] = 'null'
  end

  after(:each) do
    ENV.delete('OUTPUT_TYPE')
  end

  describe '#play' do
    it 'can play a sound file' do
      expect(Kernel).to receive(:sleep).at_least(10).times
      expect_any_instance_of(MB::Sound::NullOutput).to receive(:write).at_least(10).times.and_call_original
      expect($stderr).to receive(:puts).with(/Playing/)

      MB::Sound.play('sounds/synth0.flac', plot: false)
    end

    pending 'can play a Tone'
    pending 'can play a Numo::NArray'
    pending 'can play an array of graph nodes for separate channels'
    pending 'can play an array of other types of sounds for separate channels'

    context 'with shared_output: false' do
      it 'plays to a new output and closes it afterward' do
        outputs = []
        allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

        MB::Sound.play(440.hz.sine.for(0.05), quiet: true, shared_output: false)
        MB::Sound.play(440.hz.sine.for(0.05), quiet: true, shared_output: false)

        expect(outputs.length).to eq(2)
        expect(outputs[0]).not_to equal(outputs[1])
        expect(outputs).to all(be_closed)
      end
    end

    it 'reuses the cached output by default' do
      outputs = []
      allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

      MB::Sound.play(440.hz.sine.for(0.05), quiet: true)
      MB::Sound.play(440.hz.sine.for(0.05), quiet: true)

      expect(outputs[0]).to equal(outputs[1])
      expect(outputs[0]).not_to be_closed
    end
  end

  describe 'background playback' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    describe '#bg' do
      it 'returns reused player numbers and lists players' do
        a = MB::Sound.bg(220.hz.sine.forever)
        b = MB::Sound.bg(330.hz.sine.forever)
        expect([a, b]).to eq([1, 2])
        expect(MB::Sound.players.keys).to eq([1, 2])

        MB::Sound.stop(1, fade: 0)
        expect(MB::Sound.bg(440.hz.sine.forever)).to eq(1)
      end

      it 'accepts a name and replaces the player with the same name' do
        expect(MB::Sound.bg(:bass, 220.hz.sine.forever)).to eq(:bass)
        expect(MB::Sound.bg(:bass, 110.hz.sine.forever)).to eq(:bass)
        expect(MB::Sound.players.keys).to eq([:bass])
      end

      it 'returns right away' do
        t = MB::U.clock_now
        MB::Sound.bg(440.hz.sine.forever)
        expect(MB::U.clock_now - t).to be < 0.5
      end

      it 'mixes all players into one output' do
        outputs = []
        allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

        MB::Sound.bg(220.hz.sine.forever)
        MB::Sound.bg(330.hz.sine.forever)
        expect(outputs.length).to eq(1)
      end

      it 'rejects :all as a name' do
        expect { MB::Sound.bg(:all, 220.hz.sine) }.to raise_error(ArgumentError, /reserved/)
      end
    end

    describe '#stop' do
      it 'stops the most recently started player with no arguments' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        MB::Sound.bg(:b, 330.hz.sine.forever)
        expect(MB::Sound.stop(fade: 0)).to eq([:b])
        expect(MB::Sound.stop(fade: 0)).to eq([:a])
        expect(MB::Sound.stop).to eq([])
      end

      it 'stops named players' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        MB::Sound.bg(:b, 330.hz.sine.forever)
        expect(MB::Sound.stop(:a, fade: 0)).to eq([:a])
        expect(MB::Sound.players.keys).to eq([:b])
      end

      it 'stops everything with :all or #outro' do
        MB::Sound.bg(220.hz.sine.forever)
        MB::Sound.bg(330.hz.sine.forever)
        expect(MB::Sound.stop(:all, fade: 0)).to eq([1, 2])

        MB::Sound.bg(220.hz.sine.forever)
        expect(MB::Sound.outro(fade: 0)).to eq([1])
        expect(MB::Sound.players).to be_empty
      end

      it 'fades everything out over four bars with #outro' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        MB::Sound.bg(:b, 330.hz.sine.forever, at: :now)
        sleep 0.05
        expect(MB::Sound.outro).to contain_exactly(:a, :b)
        expect(MB::Sound.players.values).to all(end_with('(fading out)'))
      end

      it 'no longer has #hush' do
        expect(MB::Sound).not_to respond_to(:hush)
      end

      it 'fades out over four bars by default' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        sleep 0.05
        MB::Sound.stop(:a)
        expect(MB::Sound.players[:a]).to end_with('(fading out)')
        expect(MB::Sound::Session.default.fade_out).to eq(4)
      end

      it 'can fade out over a given number of bars' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        sleep 0.05
        expect(MB::Sound.stop(:a, fade: 1/10r)).to eq([:a])
        expect(MB::Sound.players[:a]).to end_with('(fading out)')
        deadline = MB::U.clock_now + 5
        sleep 0.05 until MB::Sound.players.empty? || MB::U.clock_now > deadline
        expect(MB::Sound.players).to be_empty
      end

      it 'stops everything right away with #panic, including fading and waiting players' do
        MB::Sound.bg(:a, 220.hz.sine.forever)
        MB::Sound.bg(:b, 330.hz.sine.forever)   # waits for the next bar
        sleep 0.05
        MB::Sound.stop(:a)                       # fading out over four bars
        expect(MB::Sound.players.keys).to contain_exactly(:a, :b)

        expect(MB::Sound.panic).to contain_exactly(:a, :b)
        expect(MB::Sound.players).to be_empty
        expect(MB::Sound::Session.default).to be_idle
      end

      it 'warns about unknown players' do
        expect(MB::Sound).to receive(:warn).with(/No background player 12345/)
        expect(MB::Sound.stop(12345)).to eq([])
      end
    end
  end

  describe '#render' do
    let(:filename) { 'tmp/render_spec.flac' }

    before(:each) do
      FileUtils.mkdir_p('tmp')
      File.unlink(filename) rescue nil
    end

    it 'renders a sequence for a number of bars at the current tempo' do
      bass = MB::Sound.seq(MB::Sound::C2, MB::Sound::G1).n8.loop
      seconds = MB::Sound.render(filename, bass.tone.ramp.at(1) * bass.env * 0.5, bars: 2)
      expect(seconds).to eq(4)

      data = MB::Sound.read(filename)
      expect(data.length).to eq(2)
      expect(data[0].length).to eq(4 * 48000)
      expect(data[0].abs.max).to be_between(0.1, 1)
    end

    it 'stops when every sound ends' do
      seconds = MB::Sound.render(filename, 440.hz.sine.for(0.5), bpm: 90)
      expect(seconds).to be_within(0.02).of(0.5)
    end

    it 'does not overwrite files unless asked' do
      MB::Sound.render(filename, 440.hz.sine.for(0.1))
      expect { MB::Sound.render(filename, 440.hz.sine.for(0.1)) }.to raise_error(/exists/i)
      expect { MB::Sound.render(filename, 440.hz.sine.for(0.1), overwrite: true) }.not_to raise_error
    end

    it 'does not move the live timeline' do
      MB::Sound.render(filename, 440.hz.sine.for(0.1))
      expect(MB::Sound.transport.position).to eq(0)
    end
  end

  describe '#seek and #rewind' do
    after(:each) { MB::Sound.rewind }

    it 'moves the timeline to the start of a bar' do
      MB::Sound.seek(3)
      expect(MB::Sound.transport.position).to eq(2)
      expect(MB::Sound.transport.bar).to eq(3)
      MB::Sound.rewind
      expect(MB::Sound.transport.position).to eq(0)
    end

    it 'rejects bars before the first' do
      expect { MB::Sound.seek(0) }.to raise_error(ArgumentError)
    end
  end
end
