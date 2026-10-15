RSpec.describe('MB::Sound generator clips', :aggregate_failures) do
  # 120 BPM: a bar (a whole note) is 2 seconds, 96000 samples
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:notes) { [57, 60, 62, 64, 67, 69] }

  # A generator of eighth notes drawn from +notes+, some rests, a
  # different velocity per cycle.
  def arp(seed: 3, **opts)
    list = notes
    MB::Sound::Sequence::Clip.generate(1.bar, values: list, seed: seed, **opts) { |cycle, dice|
      Array.new(8).each_index.filter_map { |i|
        next if dice.chance(0.25, :rest, i)
        [i * 1r / 8, 1r / 16, dice.pick(list, :note, i), 0.4 + 0.5 * dice.rand(:vel, i)]
      }
    }
  end

  # Edges of +clip+ in [from, to) whole notes, as plain values.
  def edges(clip, from, to)
    clip.edges(from, to).map { |t, type, e, c| [t, type, e.value, e.velocity, c] }
  end

  # Samples +node+ in buffers of +sizes+ (cycled) up to +total+ samples.
  def render(node, sizes, total)
    out = []
    n = 0
    i = 0
    while n < total
      size = [sizes[i % sizes.length], total - n].min
      b = node.sample(size)
      out << b.dup
      n += b.length
      i += 1
    end
    out.reduce(:concatenate)
  end

  describe 'Clip.generate' do
    it 'makes a looping clip whose cycles come from the block' do
      c = arp
      expect(c).to be_looping
      expect(c.length).to eq(1)
      expect(c.values).to eq(notes)
      expect(c.events).to eq(c.events_for(0))
      expect(c.events_for(1)).not_to eq(c.events_for(0))
      expect(c.events_for(5).map(&:value) - notes).to be_empty
      expect(c.to_s).to include('varying generate(seed: 3)')
      expect(c.events_for(7)).to be_frozen
    end

    it 'computes any cycle the same cold as after the cycles before it' do
      warm = arp
      seq = (0..520).map { |c| warm.events_for(c) }
      [517, 300, 0, 519, 5].each do |c|
        expect(arp.events_for(c)).to eq(seq[c]), "cycle #{c}"
      end
      # Edges over a window: cold, and after reading everything before it
      cold = edges(arp, 517, 519)
      sweep = arp
      (0...517).each { |b| sweep.edges(b, b + 1) }
      expect(edges(sweep, 517, 519)).to eq(cold)
      expect(cold).not_to be_empty
      # The same in the Ruby dice mirror
      begin
        MB::Sound::Generative::Dice.mode = :ruby
        expect(arp.events_for(517)).to eq(seq[517])
      ensure
        MB::Sound::Generative::Dice.mode = :c
      end
    end

    it 'plays the same at any buffer size' do
      # 480 BPM: a bar is 24000 samples, so four cycles stay quick at small buffers
      fast = MB::Sound::Sequence::Transport.new(bpm: 480)
      graph = -> { arp.number(transport: fast) + arp.velocity(transport: fast) * 100 + arp.trigger(transport: fast) * 1000 }
      total = 24000 * 4 + 777
      ref = render(graph.(), [800], total)
      [[13], [128], [367, 368, 1]].each do |sizes|
        got = render(graph.(), sizes, total)
        expect(got).to eq(ref), "buffer sizes #{sizes}"
      end
      expect(ref.max).to be > 1000
    end

    # Plays +graph+ in a rendering Session for +bars+ bars, after seeking
    # to bar +seek+ if given.
    def session_render(graph, bars, seek: nil)
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true, master_gain: 1)
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.bg(:a, graph, on: :now)
        MB::Sound.seek(seek) if seek
      }
      Array.new(bars * 120) { s.process_buffer[0].dup }.reduce(:concatenate)
    ensure
      s&.close
    end

    it 'plays after a seek what it plays there from the start' do
      from_start = session_render(arp.number * 0.01 + arp.velocity, 6)
      sought = session_render(arp.number * 0.01 + arp.velocity, 2, seek: 5)
      expect(sought).to eq(from_start[(96000 * 4)..])
      expect(from_start.abs.max).to be > 0.5
    end

    it 'maps generated events through transforms' do
      c = arp
      up = c.transpose(12)
      expect(up.events_for(9).map(&:value)).to eq(c.events_for(9).map { |e| e.value + 12 })
      expect(up.values).to eq(notes.map { |n| n + 12 })
      short = c.legato(0.5)
      expect(short.events_for(4).map(&:length)).to eq(c.events_for(4).map { |e| e.length / 2 })
      slow = c.stretch(2)
      expect(slow.length).to eq(2)
      expect(slow.events_for(3).map(&:start)).to eq(c.events_for(3).map { |e| e.start * 2 })
      expect(c.rotate(1r / 8).loop.events_for(2).length).to eq(c.events_for(2).length)
      # Variations after a generator change what it made
      h = c.humanize(0.01, vary: true)
      expect(h.events_for(6).map(&:value)).to eq(c.events_for(6).map(&:value))
      expect(h.events_for(6).map(&:start)).not_to eq(c.events_for(6).map(&:start))
      # Baking unrolls cycles
      baked = nil
      expect { baked = c.repeat(3) }.to output(/stop looping/).to_stderr
      expect(baked.events.length).to eq((0..2).sum { |i| c.events_for(i).length })
    end

    it 'plays a non-looping generator clip as its first cycle' do
      c = arp(loop: false)
      expect(c).not_to be_looping
      expect(edges(c, 0, 2).map { |e| e[2] }.uniq.sort).to eq(c.events_for(0).map(&:value).uniq.sort)
    end

    it 'checks what the block makes' do
      bad = ->(rows) { MB::Sound::Sequence::Clip.generate(1.bar, seed: 1) { |_c, _d| rows } }
      expect { bad.(:x) }.to raise_error(ArgumentError, /must return an Array/)
      expect { bad.([[0.5, 1r / 8, 60, 0.5]]) }.to raise_error(ArgumentError, /whole notes/)
      expect { bad.([[0r, 3r, 60, 0.5]]) }.to raise_error(ArgumentError, /reach:/)
      expect { bad.([[0r, -1r, 60, 0.5]]) }.to raise_error(ArgumentError, /negative/)
      expect { bad.([:x]) }.to raise_error(ArgumentError, /rows/)
      expect { MB::Sound::Sequence::Clip.generate(2, seed: 1) { [] } }.to raise_error(ArgumentError, /2.bars/)
      expect { MB::Sound::Sequence::Clip.generate(1.bar, seed: 1) }.to raise_error(ArgumentError, /block/)
      long = MB::Sound::Sequence::Clip.generate(1.bar, seed: 1, reach: 4.bars) { |c, _d| c.even? ? [[0r, 3r, 60, 0.5]] : [] }
      expect(long.edges(0, 4).map { |t, type, *| [t, type] }).to eq([[0, :on], [2, :on], [3, :off]])
      expect(long.edges(4, 6).map { |t, type, *| [t, type] }).to eq([[4, :on], [5, :off]])
    end

    it 'records cost per cycle' do
      c = arp(seed: 8)
      10.times { |i| c.events_for(i) }
      s = c.variations.first.block.stats
      expect(s[:cycles]).to eq(10)
      expect(s[:notes]).to eq((0...10).sum { |i| c.events_for(i).length })
      expect(s[:worst]).to be >= s[:seconds] / 10
    end
  end

  describe 'Clip#values' do
    it 'is what drum kits build voices for' do
      hits = MB::Sound::Sequence::Clip.generate(1.bar, values: [36, 42], seed: 1) { |_c, d| [[0r, 1r / 16, 36, 0.9], *(d.chance(0.5, :h) ? [[1r / 2, 1r / 16, 42, 0.5]] : [])] }
      kit = MB::Sound.tr808(hits)
      expect(kit.voices.keys.sort).to eq([:closed_hat, :kick])
      expect(MB::Sound.tr808(MB::Sound.grid(16, 'x...')).voices.keys).to eq([:kick])
      expect(MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::C3).values).to eq([48, 52])
    end
  end

  describe 'Generative::Ahead' do
    # Runs background blocks on a thread of its own, like the scheduler.
    class FakeRunner
      attr_reader :jobs

      def initialize
        @queue = Queue.new
        @jobs = 0
        @thread = Thread.new { while (job = @queue.pop) do job.call; @jobs += 1; end }
      end

      def background(&block)
        @queue << block
        true
      end

      def close
        @queue.close
        @thread.join
      end
    end

    it 'computes the next cycle in the background while cycles are read' do
      r = FakeRunner.new
      MB::Sound::Generative::Ahead.attach(r)
      c = arp(seed: 11)
      gen = c.variations.first.block
      list = (0..20).map { |i| c.events_for(i).tap { sleep 0.002 } }
      expect(gen.cached?(21)).to eq(true)
      expect(r.jobs).to be > 10
      expect(list).to eq((0..20).map { |i| arp(seed: 11).events_for(i) })
    ensure
      MB::Sound::Generative::Ahead.detach(r)
      r.close
    end

    it 'runs on a realtime session scheduler thread, and not when rendering' do
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false, channels: 1)
      expect(s.instance_variable_get(:@scheduler).background { 1 }).to eq(false)
      s.close
      rt = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: true, channels: 1)
      done = Queue.new
      expect(rt.instance_variable_get(:@scheduler).background { done << Thread.current.name }).to eq(true)
      expect(done.pop(timeout: 5)).to eq('MB::Sound::Session scheduler')
      expect(MB::Sound::Generative::Ahead.runner).to equal(rt.instance_variable_get(:@scheduler))
      rt.close
      expect(MB::Sound::Generative::Ahead.runner).not_to equal(rt.instance_variable_get(:@scheduler))
    end
  end

  describe 'strikes' do
    let(:h) { MB::Sound.harmony(0 => MB::Sound.scale(:dorian, :d), 4.bars => MB::Sound.scale(:major, :f)).blur(0.1) }

    it 'makes sparse hits from a field, at least gap steps apart' do
      s = MB::Sound.strikes(h.over(MB::Sound::A2..MB::Sound::A4, around: MB::Sound::D3), every: 1.n8, chance: 0.4, gap: 3, seed: 2)
      steps = (0...64).flat_map { |c| s.events_for(c).map { |e| c * 8 + (e.start * 8).to_i } }
      expect(steps.length).to be_between(64 * 8 * 0.08, 64 * 8 * 0.4)
      expect(steps.each_cons(2).map { |a, b| b - a }.min).to be >= 3
      vals = (0...64).flat_map { |c| s.events_for(c).map(&:value) }
      expect(vals - s.values).to be_empty
      expect(s.values).to eq((45..69).to_a)
      # Cold cycles equal warm ones, and cycle length doesn't change the hits
      s2 = MB::Sound.strikes(h.over(MB::Sound::A2..MB::Sound::A4, around: MB::Sound::D3), every: 1.n8, chance: 0.4, gap: 3, seed: 2, length: 2.bars)
      steps2 = (0...32).flat_map { |c| s2.events_for(c).map { |e| c * 16 + (e.start * 8).to_i } }
      expect(steps2).to eq(steps)
      expect { MB::Sound.strikes(h, every: 1.n4, length: 3.n8) }.to raise_error(ArgumentError, /whole number of steps/)
      expect { MB::Sound.strikes(h, chance: 2) }.to raise_error(ArgumentError, /chance/)
    end

    it 'follows the harmony: F major notes after the change, D dorian before' do
      s = MB::Sound.strikes(MB::Sound.harmony(0 => MB::Sound.scale(:dorian, :d), 4.bars => MB::Sound.scale(:major, :f), curve: :step).over(48..72), every: 1.n8, chance: 0.6, gap: 1, sharpen: 1, seed: 4)
      before = (0...4).flat_map { |c| s.events_for(c).map { |e| e.value % 12 } }.uniq
      after = (4...8).flat_map { |c| s.events_for(c).map { |e| e.value % 12 } }.uniq
      expect(before).to include(11)    # B: dorian
      expect(before).not_to include(10)
      expect(after).to include(10)     # Bb: F major
      expect(after).not_to include(11)
    end
  end

  describe 'melody on probability scales' do
    it 'walks the weighted notes, a generator with vary: true' do
      w = MB::Sound.scale(:dorian, :d).weights.blur(0.15)
      m = MB::Sound.melody(w, 8, range: MB::Sound::A3..MB::Sound::A5, vary: true, seed: 4)
      expect(m.values).to eq((57..81).to_a)
      lines = (0...40).map { |c| m.events_for(c).map(&:value) }
      expect(lines.uniq.length).to be > 30
      all = lines.flatten
      expect(all.map { |n| n % 12 }.tally.select { |pc, _| w.pc[pc] < 0.5 }.values.sum).to be_between(1, all.length / 4)
      expect(all.each_cons(2).map { |a, b| (b - a).abs }.max).to be <= 12
      expect(MB::Sound.melody(w, 8, range: MB::Sound::A3..MB::Sound::A5, vary: true, seed: 4).events_for(33)).to eq(m.events_for(33))
      fixed = MB::Sound.melody(w, 8, range: MB::Sound::A3..MB::Sound::A5, seed: 4)
      expect(fixed.variations).to be_empty
      expect(fixed.events).to eq(m.events_for(0))
      expect { MB::Sound.melody(w, weights: [1, 2]) }.to raise_error(ArgumentError, /per scale degree/)
      expect { MB::Sound.melody(w.over(48..60), range: 40..50) }.to raise_error(ArgumentError, /own range/)
    end

    it 'keeps the notes of Scale melodies' do
      a = MB::Sound.melody(MB::Sound.scale(:minor, :a), 8, seed: 3, vary: true).loop
      expect(a.events).to eq(MB::Sound.melody(MB::Sound.scale(:minor, :a), 8, seed: 3).events)
      expect(a.values).to eq(MB::Sound.scale(:minor, :a).notes(MB::Sound::A3..MB::Sound::A5).map(&:number))
      expect(a.transpose(2).events_for(3).map(&:value)).to eq(a.events_for(3).map { |e| e.value + 2 })
    end
  end

  describe 'takes' do
    let(:session) { MB::Sound::Session.new(master_gain: 0.5, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: transport, channels: 2, buffer_size: 800, realtime: false, raise_errors: true) }

    after { session.close }

    it 'replay generator clips bit for bit at any buffer size, through seeks, swaps, and drawn seeds' do
      lines = {
        0 => [
          'h = harmony(0 => scale(:dorian, :d), 2.bars => scale(:major, :f), loop: 4.bars).blur(0.2)',
          'lead = melody(h, 8, range: A3..A5, vary: true).loop',
          'bells = strikes(h.over(A4..A6), every: 1.n8, chance: 0.5)',
          "track(:lead, q: 1) { |c| c.number * 0.01 + c.velocity * 0.1 }",
          "track(:bells, q: 1) { |c| c.number * 0.003 + c.trigger * 0.2 }",
          'scene :a, lead: lead, bells: bells',
          'scene :b, lead: lead.transpose(-12), bells: :off',
          'go :a, at: :now',
        ],
        170 => ['go :b'],
        300 => ['seek 9'],
        420 => ['go :a'],
      }
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: session)
      live = Array.new(480) { |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, bnd) } }
        session.process_buffer[0].dup
      }.reduce(:concatenate)
      expect(live.abs.max).to be > 0.3

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      load path
      r = MB::Sound::Take::Replay.last
      [[800], [367, 368]].each do |sizes|
        MB::Sound.seed(5)
        out = []
        r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
        data = out.reduce(:concatenate)
        expect(data.length).to be >= live.length
        expect(data[0...live.length]).to eq(live), "buffer sizes #{sizes}"
      end
    end
  end

  describe 'recipes and graph documents' do
    def round_trip(graph, trust: nil, buffers: 30)
      text = graph.to_ruby
      loaded = MB::Sound::GraphIO.load(text, trust: trust)
      expect(loaded.to_ruby).to eq(text)
      buffers.times { expect(loaded.sample(800)).to eq(graph.sample(800)) }
      text
    end

    it 'prints strikes and probability-scale melodies back, and loads them' do
      MB::Sound.rewind
      h = MB::Sound.harmony(0 => MB::Sound.scale(:dorian, :d), 4.bars => MB::Sound.scale(:major, :f)).blur(0.2)
      g = MB::Sound.strikes(h.over(MB::Sound::A2..MB::Sound::A4, around: MB::Sound::D3), every: 1.n4, chance: 0.4, gap: 2, seed: 2).synth(voices: 2) { |v| v.hz.sine * v.env(0.005, 1, 0, 1) }
      expect(round_trip(g)).to start_with('strikes(harmony(0 => scale(:dorian, D4), 4.bars => scale(:major, F4)).blur(0.2).over(A2..A4, around: D3), every: 1.n4, chance: 0.4, gap: 2, seed: 2).synth(voices: 2)')
      m = MB::Sound.melody(MB::Sound.scale(:dorian, :d).weights.blur(0.1) + MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3) * 2, 8, range: MB::Sound::A3..MB::Sound::A5, vary: true, seed: 4).loop.tone.sine
      expect(round_trip(m)).to eq('melody(scale(:dorian, D4).weights.blur(0.1) + tones(D3, F3, A3) * 2, 8, range: A3..A5, vary: true, seed: 4).loop.tone.sine')
    end

    it 'prints generate blocks as their source (loaded with trust: :code)' do
      MB::Sound.rewind
      c = MB::Sound.generate(1.bar, values: [60, 64], seed: 9) { |_c, d| [[0r, 1r / 4, d.pick([60, 64], 0), 0.8]] }.tone
      text = c.to_ruby
      expect(text).to eq('generate(1.bar, values: [60, 64], seed: 9) { |_c, d| [[0r, 1r / 4, d.pick([60, 64], 0), 0.8]] }.tone')
      expect { MB::Sound::GraphIO.load(text) }.to raise_error(MB::Sound::GraphIO::LoadError, /trust: :code/)
      expect { round_trip(c, trust: :code) }.to output(/trust: :code/).to_stderr
    end

    it 'limits what documents may generate' do
      expect { MB::Sound::GraphIO.load('melody(scale(:minor, A4).weights, 100000)') }.to raise_error(MB::Sound::GraphIO::LoadError, /steps/)
      expect { MB::Sound::GraphIO.load('strikes(scale(:minor, A4), every: 1.n64, length: 100.bars)') }.to raise_error(MB::Sound::GraphIO::LoadError, /4096/)
      expect { MB::Sound::GraphIO.load('scale(:minor, A4).weights.over(0..400)') }.to raise_error(MB::Sound::GraphIO::LoadError, /128/)
    end
  end
end
