RSpec.describe(MB::Sound::Clock) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session(bpm: 120, buffer_size: 800, channels: 1)
    t = MB::Sound::Sequence::Transport.new(bpm: bpm)
    MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: channels, sleep: false), transport: t,
                           channels: channels, buffer_size: buffer_size, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # Renders +frames+ frames in buffers of +sizes+ (cycled), calling
  # +events+ ({ frame => proc }) before the first buffer at or after each
  # frame.  Returns channel 0.
  def render(session, frames, sizes, events = {})
    sizes = Array(sizes).cycle
    out = []
    done = 0
    pending = events.sort_by(&:first)
    while done < frames
      while (e = pending.first) && done >= e[0]
        pending.shift
        MB::Sound::Session.with_context(session: session) { e[1].call }
      end
      n = [sizes.next, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  def hits(data, min = 1e-9)
    data.to_a.each_index.select { |i| data[i].abs > min }
  end

  describe 'Tempo values' do
    it 'are exact and print as Ruby' do
      expect(138.75.bpm.to_r).to eq(555/4r)
      expect(138.7.bpm.to_r).to eq(1387/10r)
      expect(138.75.bpm.to_ruby).to eq('138.75.bpm')
      expect(165.bpm.inspect).to eq('165.bpm')
      expect(138.75.bpm / 165.bpm).to eq(37/44r)
      expect { 0.bpm }.to raise_error(ArgumentError, /positive/)
    end
  end

  describe 'positions' do
    let(:free) { MB::Sound::Clock::Free.new(rate: 48000, transport: transport) }

    it 'counts cycles of a period exactly (19.7 s is 945600 frames)' do
      c = described_class.new(19.7.seconds)
      expect(c.position(945600, free)).to eq(1)
      expect(c.position(945600 * 3 + 472800, free)).to eq(7/2r)
      expect(c.unit).to eq(:cycles)
    end

    it 'counts whole notes at its own tempo' do
      c = described_class.new(138.75.bpm)
      expect(c.position(48000, free)).to eq(555/4r / 240)
    end

    it 'splits pieces at cells' do
      c = described_class.new(1.seconds)
      pieces = c.pieces(700, 1700, free)
      expect(pieces.map { |a, b, _, _| [a, b] }).to eq([[700, 800], [800, 1600], [1600, 1700]])
      expect(pieces.map { |_, _, pos, _| pos }).to eq([700/48000r, 800/48000r, 1600/48000r])
    end
  end

  describe 'Session clocks' do
    it 'share the namespace and print readably' do
      s = new_session
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.clock(:tide, 31.1.seconds)
        MB::Sound.gear(:reese, 165 => 138.75)
        expect(s.clock!(:reese).ratio).to eq(37/44r)
        expect(MB::Sound.clocks.keys).to eq([:tide, :reese])
        expect(MB::Sound.clocks[:tide]).to match(/31.1 s period, cycle 1 \+ 0.00/)
        expect { s.arrangement.track(:tide) { |c| c.gate } }.to raise_error(ArgumentError, /already a clock/)
        expect { MB::Sound.seq(MB::Sound::C4).n4.clocked(:tid) }.to raise_error(ArgumentError, /did you mean :tide/)
        clip = MB::Sound.seq(MB::Sound::E5.n16, MB::Sound::Rest.n16).loop
        expect(clip.clocked(19.7.seconds).notes.trigger.to_ruby).to eq('seq(E5.n16, Rest.n16).loop.clocked(19.7.seconds).notes.trigger')
        expect((clip % :tide).transpose(2).notes.gate.to_ruby).to eq('seq(E5.n16, Rest.n16).loop.clocked(:tide).transpose(2).notes.gate')
      end
    end
  end

  describe '.resolve' do
    it "defines a console Session's clock in the Session that plays it (a render)" do
      console = new_session
      render = new_session
      console.define_clock(:tide, 31.1.seconds)
      allow(MB::Sound::Session).to receive(:existing).and_return(console)
      c = described_class.resolve(:tide, render)
      expect(c).not_to equal(console.clock!(:tide))
      expect(render.clock!(:tide).period).to eq(311/10r)
      expect { described_class.resolve(:tid, render) }.to raise_error(ArgumentError, /No clock :tid/)
    end
  end

  # Kaede (persona panel round 2): two bowls on 19.7 and 23.3 s and a rin
  # on 31.1 s, dropped by the hush and brought back by the tide, seeked
  # into, and replayed from a take at 367/368-frame buffers.
  describe "Kaede's bowls", render_budget: { seconds: 200, reason: "a 90 s set rendered live and replayed at 367/368 (cheap trigger graphs, ~25 s)" } do
    PERIODS = { bowl_a: 945600, bowl_b: 1118400, rin: 1492800 }.freeze
    GAINS = { bowl_a: 0.5, bowl_b: 0.25, rin: 0.125 }.freeze

    def lines
      {
        0 => [
          'clock :a, 19.7.seconds',
          'clock :b, 23.3.seconds',
          'clock :c, 31.1.seconds',
          'strike = seq(E5.n16, Rest.n16).loop.vel(1)',
          'track(:bowl_a, clock: :a) { |c| c.trigger * 0.5 }',
          'track(:bowl_b, clock: :b) { |c| c.trigger * 0.25 }',
          'track(:rin, clock: :c) { |c| c.trigger * 0.125 }',
          'track :drone, 0.0.constant',
          'scene :tide, bowl_a: strike, bowl_b: strike, rin: strike, drone: :on',
          'scene :hush, drone: :on',
          'go :tide, at: :now',
        ],
        900 => ['go :hush'],          # 15 s: lands on bar 9 (16 s)
        2700 => ['go :tide'],         # 45 s: lands on bar 24 (46 s)
        3600 => ['seek 26'],          # 60 s: the timeline jumps a bar back
      }
    end

    # Which strikes sounded: { track => frames } from summed impulses
    # (gains 4, 2, 1 eighths: the bits of the sum).
    def strikes(data)
      out = Hash.new { |h, k| h[k] = [] }
      hits(data).each do |i|
        k = (data[i] / 0.125).round
        GAINS.each { |name, g| out[name] << i if (k & (g / 0.125).round) != 0 }
      end
      out
    end

    it 'keeps every strike on its clock through scene drops, a seek, and a take replay, bit for bit at 367/368' do
      s = new_session
      b = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      take = MB::Sound::Take.new(session: s)
      out = []
      5400.times do |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { take.line(code, b) } }
        out << s.process_buffer[0].dup
      end
      live = SpecBuffers.join(out)

      by = strikes(live)
      PERIODS.each do |name, period|
        expect(by[name]).not_to be_empty
        expect(by[name].map { |f| f % period }.uniq).to eq([0]), "#{name}: #{by[name].inspect}"
      end
      # Silent while hushed (16..46 s), back after the tide, on through the seek
      expect(by.values.flatten.select { |f| f > 16 * 48000 && f < 46 * 48000 }).to eq([])
      expect(by[:bowl_a]).to eq([0, 945600 * 3, 945600 * 4]) # 0, 59.1 s, 78.8 s (after the seek)
      expect(by[:bowl_b]).to eq([0, 1118400 * 2, 1118400 * 3]) # 46.6 s, 69.9 s
      expect(by[:rin]).to eq([0, 1492800 * 2]) # 62.2 s

      path = tmp_path('kaede.rb')
      expect { take.save(path) }.to output(/Saved the take/).to_stdout
      expect(File.read(path)).to include("track(:bowl_a, clock: :a)")
      load path
      r = MB::Sound::Take::Replay.last
      replayed = []
      r.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: [367, 368], tail: 0, max_seconds: 90) { |mix| replayed << mix[0].dup }
      replayed = SpecBuffers.join(replayed)[0...live.length]
      expect(replayed.length).to eq(live.length)
      expect((replayed - live).abs.max).to eq(0)
    end
  end

  # Nev (persona panel round 2): a record pressed at 138.75 BPM inside a
  # 165 BPM set without touching bpm, and an audio loop following its own
  # clock through Sample#follow.
  describe "Nev's 138.75 inside 165" do
    it 'plays a clip at 138.75 while the set is at 165, the same as a gear clock' do
      a = new_session(bpm: 165)
      b = new_session(bpm: 165)
      riff = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3).n4.loop
      MB::Sound::Session.with_context(session: a) do
        MB::Sound.clock(:reese, 138.75.bpm)
        a.add(riff.clocked(:reese).trigger, name: :riff)
      end
      MB::Sound::Session.with_context(session: b) do
        MB::Sound.gear(:reese, 165 => 138.75)
        b.add((riff % :reese).trigger, name: :riff)
      end
      x = render(a, 96000, 800)
      y = render(b, 96000, [367, 368])
      beat = 48000 * 60 / 138.75 # 20756.76 frames
      expect(hits(x)).to eq((0...5).map { |k| (k * beat).floor })
      expect(hits(y)).to eq(hits(x))
      expect(a.transport.bpm).to eq(165)
    end

    it 'follows its own clock with an audio loop (Sample#follow clock:), lengths exact' do
      s = new_session(bpm: 165)
      beats = 2
      len = (48000 * 60 * beats / 138.75).round # a 2-beat loop recorded at 138.75
      loop_sample = MB::Sound::Sample[Numo::SFloat.new(len).seq / len, bpm: 138.75]
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.clock(:reese, 138.75.bpm)
        s.add(loop_sample.follow(:resample, clock: :reese), name: :brk)
      end
      data = render(s, len * 3 + 100, [367, 368])
      # (the cubic read crosses each wrap within a frame)
      wraps = (1...data.length).select { |i| data[i] < data[i - 1] - 0.5 }.chunk_while { |a, b| b - a < 4 }.map(&:first)
      period = 48000 * 60 * beats / 138.75
      expect(wraps.length).to eq(3)
      wraps.each_with_index { |w, k| expect(w).to be_within(1).of((k + 1) * period) }
    end
  end

  describe 'audio loops on a period, both ways', render_budget: { seconds: 200, reason: 'two 39 s loops at two buffer sizes, both fits (no effects: ~5 s)' } do
    it 'loops exactly every 19.7 s by resampling or stretching, the same at any buffer size' do
      saw = MB::Sound::Sample[Numo::SFloat.new(48000).seq / 48000]
      %i[resample stretch].each do |fit|
        runs = [800, [367, 368]].map do |sizes|
          s = new_session
          MB::Sound::Session.with_context(session: s) { s.add(saw.clocked(19.7.seconds, fit: fit, stretch: :slice), name: :x) }
          render(s, 945600 * 2 + 10, sizes)
        end
        expect((runs[0] - runs[1]).abs.max).to eq(0), fit.to_s
        if fit == :resample
          # The ramp starts again on the period's exact frames (a whole
          # source sample there: exactly 0)
          expect([runs[0][945600], runs[0][945600 * 2]]).to eq([0, 0])
          expect(runs[0][945600 - 40]).to be > 0.99
        end
      end
    end
  end

  describe 'speed' do
    it 'follows a knob turned over time, exactly at any buffer size' do
      runs = [800, [367, 368], 7].map do |sizes|
        s = new_session
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.knob(:spd, 1, range: 0.25..4, curve: :exp)
          MB::Sound.clock(:t, 0.5.seconds, speed: :spd)
          s.add(MB::Sound.seq(MB::Sound::C4.n16, MB::Sound::Rest.n16).loop.clocked(:t).trigger, name: :x)
        end
        render(s, 48000 * 4, sizes, { 0 => -> { MB::Sound.turn(:spd, 3, over: 1, at: MB::Sound.bar(2)) } })
      end
      expect(hits(runs[1])).to eq(hits(runs[0]))
      expect(hits(runs[2])).to eq(hits(runs[0]))
      gaps = hits(runs[0]).each_cons(2).map { |a, b| b - a }
      expect(gaps.first(3)).to eq([24000] * 3)
      expect(gaps.last).to be_within(800).of(8000) # 3x faster after the turn
    end
  end

  describe 'graph documents' do
    it 'save named clocks as header lines that the playing Session defines' do
      s = new_session
      text = nil
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.clock(:tide, 31.1.seconds)
        riff = MB::Sound.seq(MB::Sound::A3, MB::Sound::E4).n8.loop
        text = MB::Sound::GraphIO.dump(riff.clocked(:tide).trigger)
      end
      expect(text).to include("clock :tide, 31.1.seconds\n")
      expect(text).to include('clocked(:tide)')

      s2 = new_session
      MB::Sound::Session.with_context(session: s2) do
        g = MB::Sound::GraphIO.load(text)
        s2.add(g, name: :x)
        expect(s2.clock!(:tide).period).to eq(311/10r)
      end
      expect(hits(render(s2, 48000 * 32, 800))).to eq([0, 746400, 1492800])
    end
  end
end
