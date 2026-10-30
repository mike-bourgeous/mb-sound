RSpec.describe(MB::Sound::SidechainMethods) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames, a 16th 6000
  def new_session(channels: 1)
    out = MB::Sound::NullOutput.new(channels: channels, sleep: false)
    MB::Sound::Session.new(
      master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: channels, buffer_size: 800, realtime: false, raise_errors: true
    )
  end

  let(:session) { new_session }

  after { session.close }

  # Runs the block in +s+'s context, then renders +frames+ frames in
  # buffers of +sizes+ (cycled); returns the first channel of the mix.
  def run(frames, sizes = [800], s: session, &setup)
    MB::Sound::Session.with_context(session: s) do
      setup&.call(s)
      out = []
      left = frames
      sz = sizes.cycle
      while left > 0
        n = [sz.next, left].min
        out << s.process_buffer(n)[0].dup
        left -= n
      end
      SpecBuffers.join(out)
    end
  end

  let(:line) { MB::Sound.grid(16, 'x...x...x...x.x.').loop }

  # Frames where +data+ first falls below +level+ after being above it.
  def falls(data, level)
    (1...data.length).select { |i| data[i - 1] >= level && data[i] < level }
  end

  describe 'trigger tracks' do
    it 'are heard by readers only: nothing reaches the mix' do
      data = run(48000) { MB::Sound.sidechain(:pump, line, on: :now) }
      expect(data.abs.max).to eq(0)
      expect(session.trigger_tracks).to eq([:pump])
      expect(session.routes[:pump]).to eq({ to: nil, trigger: true })
    end

    it 'duck a part on the exact note-on samples, the same at any buffer size' do
      # One-sample buffers only around the edges they prove (frames 0 and
      # 24000: the duck from frame 0, the first fall; 96000 of them took
      # about 6 s); the other sizes over the whole bar
      ones = Array.new(32, 1)
      edges = ones + [800] * 29 + [752] + ones # (frames 0..31, 23984..24015)
      results = [[[800], 96000], [[7, 128, 333], 96000], [edges, edges.sum], [[367, 368], 96000]].map { |sizes, frames|
        s = new_session
        data = run(frames, sizes, s: s) { |ss|
          MB::Sound.sidechain(:pump, line, on: :now)
          ss.add(1.constant.duck(:pump, amount: -12.db), name: :pad, on: :now)
        }
        s.close
        data
      }
      results.each { |d| expect(d).to eq(results[0][0...d.length]) }

      data = results[0]
      expect(data.min).to be_within(1e-4).of(-12.db.to_f)
      # The gate key (velocity while each 16th is held) holds the duck
      # down through each note: the first falls from 1 come on the beats
      expect(falls(data, 0.999)).to eq([]) # (ducked from frame 0)
      expect(data[0]).to be < 1
      lows = falls(data[1000..], 0.9).map { |i| i + 1000 }
      expect(lows.first(2)).to eq([24000, 48000])
    end

    it 'take shape: :impulse (one sample per hit; a duck with attack: 0 follows it) and an envelope like env(0, 0.08)' do
      imp = run(96000) { |s|
        MB::Sound.sidechain(:pump, line, on: :now, shape: :impulse)
        s.add(MB::Sound.bus(:pump), name: :probe, on: :now)
      }
      hits = (0...imp.length).select { |i| imp[i] != 0 }
      expect(hits).to eq([0, 24000, 48000, 72000, 84000])
      expect(imp[0]).to eq(0.75)

      s2 = new_session
      env = run(96000, s: s2) { |s|
        MB::Sound.sidechain(:pump, line, on: :now, shape: MB::Sound.env(0, 0.08))
        s.add(MB::Sound.bus(:pump), name: :probe, on: :now)
      }
      expect(env[0]).to be > 0.8
      expect(env[3000]).to be < env[0]
      expect(env[24000]).to eq(env[0])

      s3 = new_session
      ducked = run(24000, s: s3) { |s|
        MB::Sound.sidechain(:pump, line, on: :now, shape: :impulse)
        s.add(1.constant.duck(:pump, amount: -12.db, attack: 0), name: :pad, on: :now)
      }
      expect(ducked[0]).to be_within(1e-5).of(-12.db.to_f)
    ensure
      s2&.close
      s3&.close
    end

    it 'play a patch block (closed hats through a drum machine) that nobody hears' do
      hats = MB::Sound.grid(16, closed_hat: 'x.x.x.x.x.x.x.x.').loop
      data = run(48000) { |s|
        MB::Sound.sidechain(:hats, hats, on: :now) { |c| MB::Sound.tr808(c) }
        s.add(MB::Sound.bus(:hats), name: :probe, on: :now)
      }
      expect(data.abs.max).to be > 0.05 # the probe plays the hats it reads
      s2 = new_session
      silent = run(48000, s: s2) { MB::Sound.sidechain(:hats, hats, on: :now) { |c| MB::Sound.tr808(c) } }
      expect(silent.abs.max).to eq(0)
    ensure
      s2&.close
    end

    it 'refuse to:, send:, feed, and CUE, and refuse a shape with a block or an unknown shape' do
      MB::Sound::Session.with_context(session: session) do
        session.bus(:verb) { |sig| sig }
        MB::Sound.sidechain(:pump)
        expect { session.route(:pump, send: { verb: 0.5 }) }.to raise_error(ArgumentError, /trigger track/)
        expect { session.route(:pump, to: :verb) }.to raise_error(ArgumentError, /trigger track/)
        expect { session.feed(:pump, :verb, 0.5) }.to raise_error(ArgumentError, /trigger track/)
        expect { MB::Sound.cue(:pump, line) }.to raise_error(ArgumentError, /trigger track/)
        expect { MB::Sound.track(:x, trigger: true, send: { verb: 0.5 }) { |c| c.gate } }.to raise_error(ArgumentError, /trigger track/)
        expect { MB::Sound.sidechain(:p2, shape: :impulse) { |c| c.gate } }.to raise_error(ArgumentError, /not both/)
        expect { MB::Sound.sidechain(:p2, shape: :boom) }.to raise_error(ArgumentError, /shape:/)
        expect { MB::Sound.sidechain(:p2, shape: MB::Sound.adsr(0, 0.1)) }.to raise_error(ArgumentError, /shape:/)
      end
    end

    it 'share the track namespace and become ordinary tracks again when redefined without trigger:' do
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.knob(:cut, 0.5)
        expect { MB::Sound.sidechain(:cut) }.to raise_error(ArgumentError, /already a knob/)
        MB::Sound.sidechain(:pump)
        expect(MB::Sound.tracks[:pump]).to include('(trigger, stopped)')
        MB::Sound.track(:pump) { |c| c.gate * 0.5 }
        expect(session.trigger_track?(:pump)).to eq(false)
      end
      data = run(800) { MB::Sound.bg(:pump, line, on: :now) }
      expect(data.max).to eq(0.5)
    end

    it 'play in scenes, launch from the clip matrix, swap, stop, and undo like tracks' do
      other = MB::Sound.grid(16, 'x.......x.......').loop.named(:half)
      data = run(4 * 96000) { |s|
        MB::Sound.sidechain(:pump, q: 1)
        s.add(MB::Sound.bus(:pump), name: :probe, on: :now)
        MB::Sound.scene(:a, pump: line)
        MB::Sound.scene(:b, pump: other)
        MB::Sound.go(:a, on: :now)
        MB::Sound.at_bar(2) { MB::Sound.go(:b) }
        MB::Sound.at_bar(3) { MB::Sound.stop(:pump) }
      }
      hits = (0...data.length).select { |i| data[i] > 0 && (i == 0 || data[i - 1] == 0) }
      expect(hits).to eq([0, 24000, 48000, 72000, 84000, 96000, 144000])
      expect(data[2 * 96000..].abs.max).to eq(0)
    end

    it 'leave no stems and keep stems summing to the mix' do
      dir = tmp_path('stems')
      path = tmp_path('mix.flac')
      MB::Sound.render(path, bars: 1, stems: dir, gain: 1) do
        MB::Sound.sidechain(:pump, line, on: :now)
        MB::Sound.bg(:pad, 0.25.constant.duck(:pump, amount: -12.db).until(1.bar), on: :now)
      end
      expect(Dir.children(dir).sort).to eq(['pad.flac'])
    end

    it 'turn down and off with their level knob, on exact frames at any buffer size, from scenes too' do
      results = [[800], [7, 128, 333], [367, 368]].map { |sizes|
        s = new_session
        d = run(3 * 96000, sizes, s: s) { |ss|
          MB::Sound.sidechain(:pump, line, on: :now)
          ss.add(MB::Sound.bus(:pump), name: :probe, on: :now)
          MB::Sound.scene(:quiet, pump: line, "pump/level": 0.5)
          MB::Sound.at_bar(2) { MB::Sound.turn(:"pump/level", 0) }
          MB::Sound.at_bar(3) { MB::Sound.go(:quiet) }
        }
        s.close
        d
      }
      results.each { |d| expect(d).to eq(results[0]) }
      data = results[0]
      expect(data[0]).to eq(0.75)
      expect(data[96000 + 960...192000].abs.max).to eq(0) # (after the turn's 5 ms glide)
      expect(data[192000 + 2400]).to eq(0.375)
      expect(session.knobs).to be_empty # (the other sessions' knobs)
    end

    # ux-fix-1 (maintainer: "Context"): the track's name stands for its
    # level wherever a knob is meant (Session::Knobs#control_name)
    it 'turn on and off by the track\'s own name in turn, scenes, sections, snapshots, and learn' do
      run(3 * 96000) { |ss|
        MB::Sound.sidechain(:pump, line, on: :now)
        ss.add(MB::Sound.bus(:pump), name: :probe, on: :now)
        expect(ss.control_name(:pump)).to eq(:"pump/level")
        MB::Sound.scene(:half, pump: 0.5)
        MB::Sound.at_bar(2) { MB::Sound.turn(:pump, 0) }
        MB::Sound.at_bar(3) { MB::Sound.go(:half) }
      }.then { |data|
        expect(data[0]).to eq(0.75)
        expect(data[96000 + 960...192000].abs.max).to eq(0)
        expect(data[192000 + 2400]).to eq(0.375) # (the line played on: the scene turned only its level)
      }
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.snap(:off, knobs: [:pump])
        session.process_buffer
        expect(session.snapshots[:off].keys).to eq([:"pump/level"])
        expect(session.knob!(:pump).name).to eq(:"pump/level")
        expect(MB::Sound::Form.section_options(:drop, pump: 0)).to eq([{}, { pump: 0 }])
      end
    end

    it 'print a hint on mute (mute doesn\'t stop a pump) pointing to the level knob and stop' do
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.sidechain(:pump, line)
        expect { MB::Sound.mute(:pump) }.to output(/trigger track: .*level :pump, 0 or stop :pump/).to_stdout
        expect { MB::Sound.unmute(:pump) }.not_to output.to_stdout
      end
    end

    it 'warn once per call site when a duck with an attack reads an impulse trigger' do
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.sidechain(:pump, line, shape: :impulse)
        expect {
          2.times { 1.constant.duck(:pump) }
        }.to output(/sidechain_methods_spec.rb:\d+: warning: duck\(:pump\) reads :pump's one-sample impulses with attack: 0.001/).to_stderr
        expect { 1.constant.duck(:pump, attack: 0) }.not_to output.to_stderr
        MB::Sound.sidechain(:gated, line)
        expect { 1.constant.duck(:gated) }.not_to output.to_stderr
      end
    end

    it 'have the aliases pump, trigger_track, trigger_line, and pumps, trigger_tracks, trigger_lines' do
      %i[pump trigger_track trigger_line].each { |a| expect(MB::Sound.method(a)).to eq(MB::Sound.method(:sidechain)) }
      %i[pumps trigger_tracks trigger_lines].each { |a| expect(MB::Sound.method(a)).to eq(MB::Sound.method(:sidechains)) }
      expect(MB::Sound.genre(:dnb) { pump :pump, :pump }.trigger_track).to eq(:pump)
    end

    it 'list with sidechains: what reads each one' do
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.sidechain(:pump, line)
        session.add(1.constant.duck(:pump), name: :pad)
        session.process_buffer(800)
        expect(MB::Sound.sidechains[:pump]).to match(/trigger.*read by pad/)
      end
    end

    it 'save in set documents as sidechain lines that load to the same text' do
      a = new_session
      b = new_session
      text = MB::Sound::Session.with_context(session: a) {
        MB::Sound.sidechain(:pump, q: 1)
        MB::Sound.sidechain(:env_trigger, shape: MB::Sound.env(0, 0.08))
        MB::Sound.sidechain(:hats, nudge: -5.ms) { |c| MB::Sound.tr808(c) }
        MB::Sound.scene(:x, pump: line, env_trigger: line, hats: MB::Sound.grid(16, closed_hat: 'xxxx').loop)
        MB::Sound::GraphIO.dump(a.arrangement, name: 'keys')
      }
      expect(text).to include("sidechain(:pump, q: 1) { |clip|\n  n = clip.notes\n  n.gate * n.velocity\n}")
      expect(text).to include('sidechain(:env_trigger) { |clip|', 'clip.env(0, 0.08)', 'sidechain(:hats, nudge: (-5).ms) { |c|')
      MB::Sound::GraphIO.load(text, session: b)
      expect(b.trigger_tracks).to eq([:pump, :env_trigger, :hats])
      expect(b.route_definitions).to eq(a.route_definitions)
      again = MB::Sound::GraphIO.dump(b.arrangement, name: 'keys')
      expect(again.sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
    ensure
      a&.close
      b&.close
    end
  end

  describe 'silent kit voices' do
    let(:machine) {
      MB::Sound.kit {
        tr909 :kick
        voice :trigger, silent: true
        voice(:ghost, silent: true) { |h| h.body(55, decay: 0.3) }
      }
    }

    it 'play for sidechains but never reach the kit mix or separate outputs' do
      src = machine.grid(16, kick: 'x...', trigger: '..x.', ghost: 'x...').loop
      k = machine.kit(src, seed: 5)
      plain = machine.kit(machine.grid(16, kick: 'x...').loop, seed: 5)
      a = SpecBuffers.join(8.times.map { k.sample(800).dup })
      b = SpecBuffers.join(8.times.map { plain.sample(800).dup })
      expect(a).to eq(b)
      expect(k.silent).to eq([:trigger, :ghost])
      expect(machine.silent_names).to eq([:trigger, :ghost])
      expect(machine.kit(src, outputs: :separate).names).to eq([:kick])
    end

    it 'key duck(:drums, only: :trigger) with a 30 ms pulse per hit on the exact sample at any buffer size' do
      src = machine.grid(16, kick: 'x...', trigger: '..x.').loop
      # One-sample buffers only around the first hit's edges (its start at
      # frame 12000 and the 30 ms pulse's end; 48000 of them took about 6 s
      # on the runner)
      ones = Array.new(32, 1)
      edges = [800] * 14 + [784] + ones + [800, 608] + ones # (frames 11984..12015, 13424..13455)
      results = [[[800], 48000], [[7, 128, 333], 48000], [edges, edges.sum]].map { |sizes, frames|
        s = new_session
        d = run(frames, sizes, s: s) { |ss|
          ss.add(machine.kit(src, seed: 5), name: :drums, on: :now)
          ss.add(MB::Sound.bus(:drums, only: :trigger) * 1000, name: :probe, on: :now)
        }
        s.close
        d
      }
      expect(results[2][12000..].abs.max).to be > 0 # (the pulse is in the one-sample run)
      results.each { |d| expect(d).to eq(results[0][0...d.length]) }
    end

    it 'without a block is a linear trigger pulse at the hit velocity' do
      src = machine.grid(16, trigger: '..X.').loop
      probe = run(24000) { |s|
        s.add(machine.kit(src, seed: 5), name: :drums, on: :now)
        s.add(MB::Sound.bus(:drums, only: :trigger), name: :probe, on: :now)
      }
      expect(probe[0...12000].abs.max).to eq(0)
      expect(probe[12000]).to be_within(1e-6).of(1)
      expect(probe[12000 + 720]).to be_within(0.01).of(0.5)
      expect(probe[12000 + 1500..12000 + 2000].abs.max).to eq(0)
    end
  end
end
