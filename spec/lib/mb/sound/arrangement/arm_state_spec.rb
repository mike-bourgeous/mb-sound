RSpec.describe(MB::Sound::Arrangement::Arm) do
  let(:arm) { MB::Sound::Arrangement::Arm }
  let(:ev) { MB::Sound::MIDI::Event }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true).tap { |s|
      sessions << s
      events = (0...40).flat_map { |i| [ev.parse([0x90, 60, 100], time: i * 0.25r), ev.parse([0x80, 60, 64], time: i * 0.25r + 0.1r)] }
      s.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
    }
  end

  def in_session(s, &block)
    MB::Sound::Session.with_context(session: s, &block)
  end

  describe 'TABLE' do
    it 'answers every (state, event) pair with a state' do
      arm::STATES.each do |state|
        expect(arm::TABLE[state].keys).to eq(arm::EVENTS)
        arm::EVENTS.each do |event|
          expect(arm::STATES).to include(arm.next_state(state, event))
        end
      end
      expect(arm::TABLE.keys).to eq(arm::STATES)
    end

    it 'disarms on disarm and panic from every state, and never leaves :disarmed except by arming' do
      arm::STATES.each do |state|
        expect(arm.next_state(state, :disarm)).to eq(:disarmed)
        expect(arm.next_state(state, :panic)).to eq(:disarmed)
      end
      (arm::EVENTS - %i[arm arm_silent]).each do |event|
        expect(arm.next_state(:disarmed, event)).to eq(:disarmed)
      end
    end

    it 'prints as a table' do
      expect(arm.table_text.lines.length).to eq(4)
      expect(arm.table_text).to match(/^monitoring\s+monitoring\s+silent\s+disarmed/)
    end

    it 'raises for unknown states and events' do
      expect { arm.next_state(:sleepy, :arm) }.to raise_error(ArgumentError, /Unknown arm state/)
      expect { arm.next_state(:silent, :poke) }.to raise_error(ArgumentError, /Unknown arm event/)
    end
  end

  describe 'panic' do
    it "disarms every armed track, says which, and journals each disarm" do
      s = new_session
      in_session(s) do
        MB::Sound.track(:y, q: 1) { |c| c.number * c.gate }
        MB::Sound.track(:z, q: 1) { |c| c.number * c.gate }
        MB::Sound.arm(:y)
        MB::Sound.arm(:z, monitor: false)
        s.process_buffer(800)
        expect(s.players.keys).to eq([:'y/live'])
        expect(s.arrangement.arms.transform_values(&:state)).to eq(y: :monitoring, z: :silent)

        expect { MB::Sound.panic }.to output(/\Apanic: stopped 1 player; disarmed :y, :z/).to_stderr
        s.process_buffer(800)
        expect(s.players).to be_empty
        expect(s.arrangement.armed).to be_empty
        expect(s.arrangement.arm_problems).to be_empty
        disarms = s.journal.changes.select { |e| e.kind == :disarm }
        expect(disarms.map(&:subject)).to eq(%i[y z])
        expect(MB::Sound.armed).to be_empty

        # Armed again, the monitor plays
        MB::Sound.arm(:y)
        expect(s.arrangement.arms[:y].state).to eq(:monitoring)
        expect(s.arrangement.arm_problems).to be_empty
      end
    end

    it 'prints no disarm part when nothing is armed' do
      s = new_session
      in_session(s) do
        expect { MB::Sound.panic }.to output("panic: stopped 0 players\n").to_stderr
      end
    end
  end

  describe 'arm states follow the monitors' do
    it 'goes silent when the monitor is stopped by name, and monitoring when the stop is undone' do
      s = new_session
      in_session(s) do
        MB::Sound.track(:y, q: 1) { |c| c.number * c.gate }
        MB::Sound.arm(:y)
        s.process_buffer(800)
        expect { MB::Sound.stop(:'y/live', fade: 0) }.not_to output.to_stderr
        expect(s.arrangement.arms[:y].state).to eq(:silent)
        expect(MB::Sound.tracks[:y]).to include('armed (no monitor)')
        expect(s.arrangement.arm_problems).to be_empty
        s.process_buffer(800)

        MB::Sound.undo(on: :now)
        expect(s.arrangement.arm_problems).to be_empty
        expect(s.arrangement.arms[:y].state).to eq(:monitoring)
      end
    end

    it 'is silent with monitor: false' do
      s = new_session
      in_session(s) do
        MB::Sound.track(:y, q: 1) { |c| c.number * c.gate }
        MB::Sound.arm(:y, monitor: false)
        expect(s.arrangement.arms.transform_values(&:state)).to eq(y: :silent)
        expect(s.arrangement.arm_problems).to be_empty
      end
    end

    # Random walks over the commands that touch armed tracks and their
    # monitors, checking the invariant (armed and monitoring <=> the
    # monitor plays or is queued) after every command and buffer.
    COMMANDS = [
      'arm :y', 'arm :z', 'arm :y, monitor: false', 'disarm :y', 'disarm', 'panic',
      'stop :"y/live", fade: 0', 'stop :"z/live", on: :bar', 'stop :y, fade: 0', 'stop :all, fade: 0',
      'forget', 'undo on: :now', 'undo', 'redo! on: :now', 'seek 1', 'seek 2, on: :bar',
      'go :both', 'go :none', 'bg :y, seq(C4).n4.loop', 'resume :"y/live"',
      'track(:y, q: 1) { |c| c.number * c.gate * 2 }',
    ].freeze

    # (seeds that found bugs, walked every run: 9509, a scene's queued swap
    # landing after `forget` removed the player, omnibus13; 44818, a queued
    # swap landing after other commands left the player playing none of
    # its clips, 2026-10-26)
    [nil, 9509, 44818].each do |fixed|
    it "keeps the invariant through random walks of commands (seed #{fixed || 'from RSpec'})" do
      rng = Random.new(fixed || RSpec.configuration.seed)
      8.times do |walk|
        s = new_session
        b = MB::Sound::Take.console_binding
        log = []
        in_session(s) do
          MB::Sound.track(:y, q: 1) { |c| c.number * c.gate }
          MB::Sound.track(:z, q: 1) { |c| c.number * c.gate }
          MB::Sound.scene(:both, y: MB::Sound.seq(MB::Sound::C4).n4.loop, z: MB::Sound.seq(MB::Sound::E4).n4.loop)
          MB::Sound.scene(:none)
        end
        40.times do
          code = COMMANDS.sample(random: rng)
          log << code
          old_err = $stderr
          $stderr = StringIO.new # (panic, stop, and undo print what they did)
          begin
            in_session(s) { b.eval(code) }
          rescue ArgumentError => e
            # (live_errors such as resuming a disarmed track's monitor)
            log[-1] = "#{code} (#{e.message[0, 40]})"
          ensure
            $stderr = old_err
          end
          problems = s.arrangement.arm_problems
          expect(problems).to be_empty, "after #{log.inspect}: #{problems.inspect}"
          rng.rand(3).times do
            begin
              s.process_buffer(800)
            rescue StandardError => e
              raise e.class, "#{e.message}\nafter #{log.inspect} (walk #{walk})", e.backtrace
            end
            problems = s.arrangement.arm_problems
            expect(problems).to be_empty, "after #{log.inspect} and buffers: #{problems.inspect}"
          end
        end
      end
    end
    end
  end
end
