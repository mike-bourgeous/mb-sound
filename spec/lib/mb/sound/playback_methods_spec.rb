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
    # Waits up to +timeout+ seconds for the block to return true.
    def wait_for(timeout = 5)
      deadline = MB::U.clock_now + timeout
      sleep 0.01 until yield || MB::U.clock_now > deadline
      yield
    end

    after(:each) do
      MB::Sound.stop
    end

    describe '#bg' do
      it 'returns increasing player numbers and lists players' do
        a = MB::Sound.bg(220.hz.sine.forever)
        b = MB::Sound.bg(330.hz.sine.forever)

        expect(a).to be_a(Integer)
        expect(b).to eq(a + 1)
        expect(MB::Sound.players.keys).to eq([a, b])
        expect(MB::Sound.players[a]).to be_a(String)
      end

      it 'returns right away and removes the player when the sound ends' do
        t = MB::U.clock_now
        id = MB::Sound.bg(440.hz.sine.for(0.2))
        expect(MB::U.clock_now - t).to be < 0.1

        expect(MB::Sound.players).to include(id)
        expect(wait_for { !MB::Sound.players.include?(id) }).to eq(true)
      end

      it 'gives each player its own output and closes it' do
        outputs = []
        allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

        MB::Sound.bg(220.hz.sine.for(0.1))
        MB::Sound.bg(330.hz.sine.for(0.1))
        expect(wait_for { MB::Sound.players.empty? }).to eq(true)

        expect(outputs.length).to eq(2)
        expect(outputs[0]).not_to equal(outputs[1])
        expect(outputs).to all(be_closed)
      end

      it 'does not print the playing header' do
        expect($stderr).not_to receive(:puts)
        id = MB::Sound.bg(440.hz.sine.for(0.05))
        wait_for { !MB::Sound.players.include?(id) }
      end
    end

    describe '#stop' do
      it 'stops one player and returns its number' do
        a = MB::Sound.bg(220.hz.sine.forever)
        b = MB::Sound.bg(330.hz.sine.forever)

        expect(MB::Sound.stop(a)).to eq([a])
        expect(MB::Sound.players.keys).to eq([b])
      end

      it 'stops all players when given no numbers' do
        ids = [MB::Sound.bg(220.hz.sine.forever), MB::Sound.bg(330.hz.sine.forever)]
        expect(MB::Sound.stop).to eq(ids)
        expect(MB::Sound.players).to be_empty
      end

      it 'warns about unknown players' do
        expect(MB::Sound).to receive(:warn).with(/No background player 12345/)
        expect(MB::Sound.stop(12345)).to eq([])
      end
    end
  end
end
