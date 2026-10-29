# G4 long form: markov and lsystem section sources, `generate` steps in
# flows (sections decided as the flow plays), Form::Plan (the same
# decisions worked out ahead), and seeks into generated pieces.
RSpec.describe('MB::Sound generative long form (G4)', :aggregate_failures) do
  # 480 BPM at 48 kHz: one bar (a whole note) is 24000 frames (long forms, short renders)
  let(:bar) { 24000 }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session(buffer_size: 800)
    s = MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 480),
      channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true
    )
    sessions << s
    s
  end

  def within(session, &block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def moods(seed: 7, **extra)
    MB::Sound.markov(still: { drift: 3, hush: 1 }, drift: { bloom: 3, still: 1 }, bloom: { hush: 2, drift: 1 }, hush: { still: 1 }, seed: seed, **extra)
  end

  # A session whose one track outputs the note number of the scene playing
  # (one scene per name, notes 48, 50, 52, ...).
  def note_session(names, buffer_size: 800)
    s = new_session(buffer_size: buffer_size)
    s.arrangement.track(:x) { |c| c.notes.number }
    names.each_with_index { |n, i| s.arrangement.scene(n, x: MB::Sound.seq(48 + 2 * i).n1.loop) }
    s
  end

  def run(session, frames, sizes: [800])
    out = []
    n = 0
    i = 0
    while n < frames
      out << session.process_buffer(sizes[i % sizes.length])[0].dup
      n += out.last.length
      i += 1
    end
    SpecBuffers.join(out)[0...frames]
  end

  describe 'markov' do
    it 'is a pure function of its seed: draws cold equal draws in order' do
      m = moods
      list = m.take(600)
      expect(list.first(8)).to eq(%i[still drift bloom drift bloom hush still drift])
      expect(moods[599]).to eq(list[599]) # a fresh chain, cold
      expect(moods(seed: 8).take(600)).not_to eq(list)
      expect(list.tally.keys).to contain_exactly(:still, :drift, :bloom, :hush)
      # still -> hush or drift only
      list.each_cons(2) { |a, b| expect(%i[drift hush]).to include(b) if a == :still }
    end

    it 'takes second-order rules over first-order ones, and starts over after an end' do
      m = MB::Sound.markov(intro: { verse: 1 }, verse: { chorus: 1, verse: 3 }, chorus: { verse: 1, outro: 1 },
                           [:verse, :verse] => { chorus: 1 }, outro: {}, seed: 3)
      expect(m.order).to eq(2)
      list = m.take(400)
      list.each_cons(3) { |a, b, c| expect(c).to eq(:chorus) if a == :verse && b == :verse }
      list.each_cons(2) { |a, b| expect(b).to eq(:intro) if a == :outro }
      expect(m.terminal?(:outro)).to eq(true)
    end

    it 'prints itself back as the call that builds it' do
      m = MB::Sound.markov(intro: { verse: 1 }, verse: { chorus: 2, verse: 1 }, chorus: { verse: 1, outro: 0.5 }, outro: {}, seed: 3)
      expect(m.to_ruby).to eq('markov(intro: { verse: 1 }, verse: { chorus: 2, verse: 1 }, chorus: { verse: 1, outro: 0.5 }, outro: {}, seed: 3)')
      expect(MB::Sound.module_eval(m.to_ruby)).to eq(m)
      pairs = MB::Sound.markov({ a: { b: 1 }, b: { a: 1 }, [:a, :b] => { b: 1 } }, start: :b, seed: 1)
      expect(MB::Sound.module_eval(pairs.to_ruby)).to eq(pairs)
      expect(MB::Sound.module_eval(pairs.to_ruby).take(20)).to eq(pairs.take(20))
    end

    it 'checks its rules' do
      expect { MB::Sound.markov(a: { b: 1 }, seed: 1) }.to raise_error(ArgumentError, /no rule for :b/)
      expect { MB::Sound.markov(drift: { blom: 1 }, bloom: { drift: 1 }, seed: 1) }.to raise_error(ArgumentError, /no rule for :blom.*Did you mean\?\s+:bloom/m)
      expect { MB::Sound.markov(a: { a: 0 }, seed: 1) }.to raise_error(ArgumentError, /every weight after :a is zero.*:a => \{\} for an end/)
      expect { MB::Sound.markov(a: { a: -1 }, seed: 1) }.to raise_error(ArgumentError, /weights are numbers of at least 0/)
      expect { MB::Sound.markov(a: [:a], seed: 1) }.to raise_error(ArgumentError, /needs a Hash of next states/)
      expect { MB::Sound.markov(seed: 1) }.to raise_error(ArgumentError, /markov needs rules/)
    end
  end

  describe 'lsystem' do
    let(:song) {
      MB::Sound.lsystem(%i[intro body outro], body: { %i[build drop body] => 2, %i[build drop breakdown drop2] => 1 }, generations: 4, seed: 5)
    }

    it 'rewrites every symbol each generation, drawing stochastic rules from its seed' do
      det = MB::Sound.lsystem(%i[a], a: %i[a b], b: :a, generations: 5, seed: 1)
      expect(det.word.join).to eq('abaababaabaab') # the Fibonacci word
      expect(det.word.length).to eq(13)
      w = song.word
      expect(w.first).to eq(:intro)
      expect(w.last).to eq(:outro)
      expect(song.word).to equal(w) # cached
      seeds = (1..20).map { |sd| MB::Sound.lsystem(%i[intro body outro], body: song.rules[:body].to_h, generations: 4, seed: sd).word }
      expect(seeds.uniq.length).to be > 2
    end

    it 'leaves nonterminals out of flows and prints itself back' do
      f = song.flow(intro: 8, build: 4, drop: [8, 16], breakdown: 8, drop2: 16, outro: 8)
      expect(f.plays.map(&:first)).to eq(song.word.reject { |x| x == :body })
      expect(f.plays.map(&:last).values_at(*f.plays.each_index.select { |i| f.plays[i][0] == :drop }).uniq - [8, 16]).to be_empty
      expect(song.to_ruby).to eq('lsystem(%i[intro body outro], body: { %i[build drop body] => 2, %i[build drop breakdown drop2] => 1 }, generations: 4, seed: 5)')
      expect(MB::Sound.module_eval(song.to_ruby).word).to eq(song.word)
    end

    it 'grows a new word for each visit with vary: true' do
      v = MB::Sound.lsystem(%i[a b], a: { %i[a c] => 1, %i[c] => 1 }, b: { %i[b c] => 1, %i[c c] => 1 }, generations: 3, seed: 2, vary: true)
      words = (0..5).map { |k| v.word(visit: k) }
      expect(words.uniq.length).to be > 1
      expect(v.word(visit: 3)).to eq(words[3])
    end

    it 'checks its rules and limits' do
      expect { MB::Sound.lsystem([], {}, seed: 1) }.to raise_error(ArgumentError, /axiom is a word of Symbols/)
      expect { MB::Sound.lsystem(%i[a], a: 3, seed: 1) }.to raise_error(ArgumentError, /rewrites to a word/)
      expect { MB::Sound.lsystem(%i[a], a: %i[a a], generations: 13, seed: 1).word }.to raise_error(ArgumentError, /at most 4096/)
    end
  end

  describe 'generate steps' do
    it 'declares the sections it gives lengths to, checks the rest, and prints back' do
      m = moods
      f = MB::Sound::Form.build { intro 2; label :top; generate m, still: 6, drift: 4..8, bloom: [8, 12], hush: 4; goto :top }
      expect(f.sections.keys).to eq(%i[intro still drift bloom hush])
      expect(f.sections[:drift].length).to eq(4)
      expect(f.generative?).to eq(true)
      expect(f.to_ruby).to eq(<<~RUBY.chomp)
        flow do
          intro 2
          label :top
          generate #{m.to_ruby}, bars: { still: 6, drift: 4..8, bloom: [8, 12], hush: 4 }
          goto :top
        end
      RUBY
      again = MB::Sound.module_eval(f.to_ruby.sub('flow do', 'MB::Sound::Form.build do'))
      expect(again).to eq(f)
      expect(again.plan(seed: 1).first(30).map(&:to_h)).to eq(f.plan(seed: 1).first(30).map(&:to_h))

      expect { MB::Sound::Form.build { generate m, still: 6 } }.to raise_error(ArgumentError, /no length for :drift, :bloom, :hush/)
      expect { MB::Sound::Form.build { generate m, still: 6, drift: 0..2, bloom: 1, hush: 1 } }.to raise_error(ArgumentError, /Range of lengths is whole bars/)
      expect { MB::Sound::Form.build { generate :x } }.to raise_error(ArgumentError, /needs a section source/)
      # Declared sections keep their options
      g = MB::Sound::Form.build { hush 4, fill: :roll; generate m, still: 6, drift: 8, bloom: 8 }
      expect(g.sections[:hush].fill.names).to eq([:roll])
    end

    it 'plays what the chain draws, with lengths drawn per occurrence, the same as its plan' do
      m = moods
      f = m.flow(still: 1, drift: 1..3, bloom: [1, 2], hush: 1)
      plan = f.plan(seed: 1).first(25)
      expect(plan.map(&:section)).to eq(m.take(25))
      expect(plan.map(&:length).uniq.sort).to eq([1, 2, 3])
      # The written-out form plays the same sections for the same lengths
      w = m.flow({ still: 1, drift: 1..3, bloom: [1, 2], hush: 1 }, sections: 25)
      expect(w.plays.map { |n, _, l| [n, l] }).to eq(plan.map { |p| [p.section, p.length] })

      s = note_session(%i[still drift bloom hush])
      pb = within(s) { MB::Sound.play_form(f, seed: 1, on: :now) }
      data = run(s, 40 * bar)
      expect(pb.played.first(plan.length - 5)).to eq(plan.first(plan.length - 5).map { |p| [p.section, p.length] })
      # Each section's note from its plan start
      plan.select { |p| p.stop < 39 }.each do |p|
        expect(data[(p.start * bar).to_i + 10]).to eq(48 + 2 * %i[still drift bloom hush].index(p.section)), "#{p.section} at #{p.start}"
      end
    end

    it 'plays sections: per visit, then carries on; an ending chain falls through; finish ends a generated flow' do
      m = MB::Sound.markov(a: { b: 1 }, b: { a: 1, c: 1 }, c: { a: 1 }, seed: 4)
      f = MB::Sound::Form.build { label :top; generate m, sections: 3, a: 1, b: 1, c: 1; brk 1; goto :top }
      names = f.plan(seed: 1).first(16).map(&:section)
      expect(names.each_slice(4).map(&:last)).to all(eq(:brk))
      # the chain carries on across visits
      expect(names.reject { |n| n == :brk }).to eq(m.take(12))

      m = MB::Sound.markov(a: { b: 1 }, b: { a: 1, c: 1 }, c: {}, seed: 4)
      ending = MB::Sound::Form.build { intro 1; generate m, a: 1, b: 1, c: 1; outro 1 }
      seq = ending.plan(seed: 1).map(&:section)
      expect(seq.first).to eq(:intro)
      expect(seq.last(2)).to eq(%i[c outro])

      # finish: a flow of only generate steps has no last section, so it ends
      s = note_session(%i[still drift bloom hush])
      chain = moods
      pb = within(s) { MB::Sound.play_form(MB::Sound::Form.build { generate chain, still: 1, drift: 1, bloom: 1, hush: 1 }, seed: 1, on: :now) }
      run(s, bar / 8)
      within(s) { MB::Sound.finish }
      run(s, 3 * bar)
      expect(pb.history.length).to eq(1)
      expect(pb.ended?).to eq(true)
    end

    it 'plays a generated section next on goto, the chain carrying on from it' do
      m = moods
      f = m.flow(still: 1, drift: 1, bloom: 1, hush: 1)
      s = note_session(%i[still drift bloom hush])
      pb = within(s) { MB::Sound.play_form(f, seed: 1, on: :now) }
      run(s, bar / 8) # (before the scheduler's half-bar lookahead starts the next pass)
      within(s) { MB::Sound.goto(:hush) }
      run(s, 3 * bar)
      expect(pb.history.first(3)).to eq(%i[still hush still]) # hush -> still is its only rule
    end

    it 'reads knob-steered weights at each commit point, at any buffer size, and replays them in takes' do
      render = lambda { |sizes, lines|
        s = note_session(%i[still drift bloom hush], buffer_size: sizes.max)
        within(s) {
          MB::Sound.knob :motion, 0.0, range: 0.0..1.0
          m = MB::Sound.markov(still: { drift: 1 }, drift: { bloom: MB::Sound.knob(:motion), still: 0.01 }, bloom: { drift: 1 }, hush: { still: 1 }, seed: 2)
          MB::Sound.play_form(m.flow(still: 1, drift: 1, bloom: 1, hush: 1), seed: 1, on: :now)
        }
        frames = 0
        out = []
        i = 0
        while frames < 12 * bar
          lines.fetch(frames / bar, nil)&.then { |code| within(s) { MB::Sound.instance_eval(code) } if frames % bar < sizes.max && (i += 1) }
          out << s.process_buffer(sizes[out.length % sizes.length])[0].dup
          frames += out.last.length
        end
        [s.arrangement.playback.history, SpecBuffers.join(out)[0...(12 * bar)]]
      }
      # :motion turned up at bar 5 (position 4): drift -> bloom from the
      # commit point at the end of the next drift pass
      h, data = render.call([800], { 4 => 'turn :motion, 1.0' })
      before = h.first(4)
      expect(before).to eq(%i[still drift still drift])
      expect(h.drop(5).each_cons(2).count { |a, b| a == :drift && b == :bloom }).to be >= 2
      slow_tier([[367, 368], [1000, 13]], keep: 1).each do |sizes|
        h2, data2 = render.call(sizes, { 4 => 'turn :motion, 1.0' })
        expect(h2).to eq(h)
        expect(data2).to eq(data), "buffer sizes #{sizes}"
      end
    end

    it 'replays a generated flow from a take bit for bit', render_budget: { seconds: 100, reason: 'a 25 s take recorded, then replayed at 800 and (slow tier) 367/368' } do
      s = new_session
      lines = {
        0 => ['track(:x) { |c| c.notes.number }',
              *%i[still drift bloom hush].each_with_index.map { |n, i| "scene :#{n}, x: seq(#{48 + 2 * i}).n1.loop" },
              'm = markov(still: { drift: 3, hush: 1 }, drift: { bloom: 3, still: 1 }, bloom: { hush: 2, drift: 1 }, hush: { still: 1 })',
              'flow { label :top; generate m, still: 1, drift: 1..2, bloom: [1, 2], hush: 1; goto :top }'],
        300 => ['goto :hush'],
        700 => ['seek 17'],
      }
      bnd = MB::Sound::Take.console_binding
      MB::Sound.seed(5)
      t = MB::Sound::Take.new(session: s)
      out = []
      1500.times do |i|
        lines.fetch(i, []).each { |code| within(s) { t.line(code, bnd) } }
        out << s.process_buffer[0].dup
      end
      live = SpecBuffers.join(out)
      expect(s.arrangement.playback.history).to include(:hush)

      [[800], *slow_tier([[367, 368]], keep: 0)].each do |sizes|
        MB::Sound.seed(5)
        got = []
        t.replay.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| got << mix[0].dup }
        got = SpecBuffers.join(got)
        expect((got[0...live.length] - live).abs.max).to eq(0), "buffer sizes #{sizes}"
      end
    end
  end

  describe 'cold seeks' do
    let(:names) { %i[still drift bloom hush] }
    let(:form) { moods.flow(still: 1, drift: 1..3, bloom: [1, 2], hush: 1) }

    it 'finds the pass at any position from the plan, cold or in order' do
      plan = form.plan(seed: 1)
      deep = plan.at(5000)
      expect(deep.start).to be <= 5000
      expect(deep.stop).to be > 5000
      cold = form.plan(seed: 1).at(5000)
      expect(cold).to eq(deep)
      expect(form.plan(seed: 1).find(:hush, from: 100).section).to eq(:hush)
    end

    it 'plays on after a seek to a bar from the pass an uninterrupted run plays there' do
      target = 61 # bar 61: whole note 60
      ref = note_session(names)
      within(ref) { MB::Sound.play_form(form, seed: 1, on: :now) }
      ref_data = run(ref, 80 * bar)

      s = note_session(names)
      pb = within(s) { MB::Sound.play_form(form, seed: 1, on: :now) }
      run(s, bar)
      within(s) { MB::Sound.seek(target) }
      got = run(s, 19 * bar + bar / 2)
      pass = form.plan(seed: 1).at(target - 1)
      expect(pb.played[1]).to eq([pass.section, pass.length])
      # From the seek on, the same notes as the uninterrupted run (the
      # pass's scene launched at the seek, the clips following the
      # timeline; +got+ starts where the seek lands, on whole note 60)
      from = (target - 1) * bar
      expect(got[0...(18 * bar)]).to eq(ref_data[from...(from + 18 * bar)])
      expect(pb.played.drop(1).first(6)).to eq(form.plan(seed: 1).lazy.drop_while { |x| x.stop <= target - 1 }.first(6).map { |x| [x.section, x.length] })
    end

    it 'seeks to a generated section by name: where an uninterrupted run next plays it' do
      s = note_session(names)
      pb = within(s) { MB::Sound.play_form(form, seed: 1, on: :now) }
      run(s, bar / 2)
      within(s) { MB::Sound.seek(:hush) }
      run(s, 800)
      first_hush = form.plan(seed: 1).find(:hush)
      expect(s.transport.position).to be_within(1/30r).of(first_hush.start) # (a buffer after the seek)
      expect(pb.section).to eq(:hush)
    end
  end
end
