# Graph-io phase 3: set documents (kind: :set), the Set layer saved and
# loaded so a set can be reopened.
require_relative '../../../support/graph_sweep'

# Sets for the spec below, written in MB::Sound so note names resolve as in
# the console.
module MB::Sound
  module GraphIOSetSpec
    def self.const_missing(name)
      MB::Sound.const_get(name)
    end

    # A set with knobs, a master chain, patch and graph tracks, named and
    # captured clips, scenes with knob values, a mute group, a section, and
    # a flow with labels, gotos, picks, and repeats.  With +drums+, an 808
    # track (its voices draw random seeds).
    def self.build(drums: true)
      MB::Sound.instance_exec do
        bpm 132
        knob :cut, 900, range: 100..8000, curve: :exp, unit: 'Hz'
        master { |mix| mix.softclip(0.5, 0.97) }
        bass_a = acid(A1, R, !A1, ~C2, R, G1, E1, R).loop.named(:bass_a)
        bass_b = bass_a.transpose(5).named(:bass_b)
        lead = events([0r, 1/8r, 69, 0.8], [3/8r, 1/8r, 72, 0.6], length: 1r/2, loop: true).named(:lead_1)
        track(:bass) { |clip|
          v = clip.synth(voices: 1) { |n| n.hz.ramp.lp4(knob(:cut), resonance: 0.3) * n.amp_env(0.003, 0.2, 0.4, 0.1) }
          v * 0.5
        }
        track(:lead, lead: 0.5.attack) { |c| c.synth(voices: 2) { |v| v.hz.saw.at(-12.db) * v.amp_env(0.05, 0.1, 0.6, 0.3) }.delay(3.n16, feedback: 0.3, wet: 0.3) }
        track :drone, 55.hz.triangle.at(-24.db)
        drop = { bass: bass_b, lead: lead, drone: :on, cut: [2600, { over: 2 }] }
        if drums
          beat = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop.named(:beat)
          track(:drums, q: 4) { |kit| tr808(kit, accent: 6) * 0.8 }
          drop[:drums] = beat
          scene :fill, drums: beat, others: :keep
          mutes :rhythm, :drums, :bass
        end
        scene :intro, bass: bass_a, drone: :on, cut: 600
        scene :drop, **drop
        section :outro, 2, scene: :intro, fade: 1
        flow(play: false) do
          intro 2
          label :top
          drop 2
          pick do |p|
            p.option(2) { intro }
            p.option(1) { }
          end
          repeat 2 do
            drop times: 1
          end
          goto :top, times: 1
          outro
        end
      end
    end
  end
end

RSpec.describe('set documents', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def within(s, &block)
    MB::Sound::Session.with_context(session: s, &block)
  end

  # The set's flow from the start (seeded chance), +buffers+ x 800 frames.
  def play(s, form, buffers)
    within(s) { MB::Sound.play_form(form, on: :now, seed: 5) }
    Array.new(buffers) { s.process_buffer.map(&:dup) }.transpose.map { |c| c.reduce(:concatenate) }
  end

  def stable(text)
    text.sub(/saved: "[^"]*"/, '')
  end

  it 'saves a set as its console commands' do
    s = session
    within(s) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build }
    text = io.dump(s.arrangement, name: 'demo')
    expect(text).to start_with('# mb-sound set document')
    expect(text).to include('graph 2, name: "demo", kind: :set')
    expect(text).to include(<<~RUBY)
      knob :cut, 900.0, range: 100.0..8000.0, curve: :exp, unit: "Hz"

      bpm 132
      master_gain 1.0
      bass_a = acid(A1, Rest, !A1, ~C2, Rest, G1, E1, Rest).loop.named(:bass_a)
      bass_b = bass_a.transpose(5).named(:bass_b)
      lead_1 = events([0r, 1r/8, 69, 0.8], [3r/8, 1r/8, 72, 0.6], length: 1r/2, loop: true).named(:lead_1)
      beat = grid(16, kick: "x...x...x...x...", hat: "..x...x...x...x.").loop.named(:beat)
      master { |mix|
        mix.softclip(0.5, 0.97)
      }
      track(:bass) { |clip|
        v = clip.synth(voices: 1) { |n|
          n.hz.ramp.lp4(cut, resonance: 0.3) * n.amp_env(0.003, 0.2, 0.4, 0.1)
        }
        v * 0.5
      }
      track(:lead, lead: 0.5.attack) { |c|
    RUBY
    expect(text).to include("track :drone, 55.hz.triangle.at(-24.db)\n")
    expect(text).to match(/track\(:drums, q: 4\) \{ \|kit\|\n  tr808\(kit, accent: 6, seed: drawn_seed\(\d+\)\) \* 0.8\n\}/)
    expect(text).to include(<<~RUBY)
      scene :fill, drums: beat, others: :keep
      scene :intro, bass: bass_a, drone: :on, cut: 600
      scene :drop, bass: bass_b, lead: lead_1, drone: :on, cut: [2600, { over: 2 }], drums: beat
      mutes :rhythm, :drums, :bass
      section :outro, 2, scene: :intro, fade: 1
      flow do
        intro 2
        label :top
        drop 2
        pick do |p|
          p.option(2) { intro }
          p.option(1) { }
        end
        repeat 2 do
          drop times: 1
        end
        goto :top, times: 1
        outro 2, scene: :intro, fade: 1
      end
    RUBY
  end

  it 'saves and loads a post-chain master gain' do
    a = session
    within(a) { MB::Sound.master_gain(-3.db, post: true) }
    text = io.dump(a.arrangement, name: 'post')
    expect(text).to include("master_gain -3.db, post: true\n")

    b = session
    io.load(text, session: b)
    expect(b.master_gain_post?).to eq(true)
    expect(b.master_gain).to eq(-3.db.to_f)
  end

  it 'loads a set into a session that plays it like the original' do
    a = session
    within(a) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build(drums: false) }
    text = io.dump(a.arrangement, name: 'demo')

    b = session
    doc = io.load(text, session: b)
    expect(doc.kind).to eq(:set)
    expect(doc.session).to equal(b)
    expect(b.arrangement.tracks.keys).to eq(%i[bass lead drone])
    expect(b.arrangement.scenes.keys).to eq(%i[intro drop])
    expect(b.knobs[:cut].target).to eq(900)
    expect(b.transport.bpm).to eq(132)
    expect(b.master_gain).to eq(1.0)
    expect(doc.inspect).to include('set: tracks bass, lead, drone; scenes intro, drop; a flow')

    ref = play(a, a.arrangement.last_form, 400)
    got = play(b, doc.form, 400)
    expect(ref[0].abs.max).to be > 0.05
    expect(RecipeHelpers.max_diff(ref, got)).to eq(0)
  end

  it 'saves a loaded set again to the same text, playing bit for bit' do
    a = session
    within(a) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build }
    text = io.dump(a.arrangement, name: 'demo')
    b = session
    doc = io.load(text, session: b)
    again = io.dump(b.arrangement, name: 'demo')
    expect(stable(again)).to eq(stable(text))

    c = session
    doc2 = io.load(again, session: c)
    x = play(b, doc.form, 300)
    y = play(c, doc2.form, 300)
    expect(x[0].abs.max).to be > 0.05
    expect(RecipeHelpers.max_diff(x, y)).to eq(0)
  end

  it 'builds patches to save them without a TracePoint (YJIT would drop its code)' do
    a = session
    within(a) { MB::Sound::GraphIOSetSpec.build }
    expect(TracePoint).not_to receive(:new)
    text = io.dump(a.arrangement, name: 'demo')
    expect(text).to include("track(:bass) { |clip|\n  v = clip.synth(voices: 1) { |n|")
  end

  it 'plays the saved seeds, or fresh ones with seeds: :fresh' do
    a = session
    within(a) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build }
    text = io.dump(a.arrangement, name: 'demo')
    expect(text).to match(/tr808\(kit, accent: 6, seed: drawn_seed\(\d+\)\)/)

    build = ->(s, **opts) {
      io.load(text, session: s, **opts)
      within(s) { s.arrangement.tracks[:drums].patch.call(s.arrangement.scenes[:drop].values[:drums]) }
    }
    saved = [build.(session), build.(session)].map { |g| g.to_ruby(seeds: true)[/seed: \d+/] }
    expect(saved.uniq.length).to eq(1)
    MB::Sound.seed(10)
    fresh = [build.(session, seeds: :fresh), build.(session, seeds: :fresh)].map { |g| g.to_ruby(seeds: true)[/seed: \d+/] }
    expect(fresh.uniq.length).to eq(2)
    expect(fresh).not_to include(saved[0])
    expect { io.load(text, session: session, seeds: :new) }.to raise_error(ArgumentError, /seeds: must be :saved or :fresh/)
  end

  it 'keeps the random state while building patches to save them' do
    a = session
    within(a) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build }
    before = MB::Sound.next_seed
    within(a) { MB::Sound.seed(3); MB::Sound::GraphIOSetSpec.build }
    io.dump(a.arrangement, name: 'demo')
    expect(MB::Sound.next_seed).to eq(before)
  end

  it 'saves sets with save :name, set and loads them with preset' do
    dir = File.dirname(tmp_path('presets/x'))
    FileUtils.mkdir_p(dir)
    allow(io).to receive(:presets_dir).and_return(dir)
    allow(io).to receive(:user_presets_dir).and_return(dir)
    a = session
    path = nil
    within(a) {
      MB::Sound::GraphIOSetSpec.build(drums: false)
      expect(MB::Sound.set).to equal(a.arrangement)
      expect { path = MB::Sound.save(:gig, MB::Sound.set) }.to output(/Saved gig to .*gig.mbg.rb/).to_stdout
    }
    b = session
    doc = nil
    within(b) { expect { doc = MB::Sound.preset(:gig) }.to output(/Loaded set gig: tracks bass, lead, drone; scenes intro, drop; play_form doc.form/).to_stdout }
    expect(doc.session).to equal(b)
    expect(io.parse(path).kind).to eq(:set)
  end

  it 'has console names that collide with nothing' do
    require 'pry'
    %i[set current_set].each do |n|
      expect(MB::Sound.method(n).owner).to eq(MB::Sound::GraphIOMethods)
      expect(Object.new.respond_to?(n, true)).to eq(false)
      expect(Pry::Commands.keys.map(&:to_s)).not_to include(n.to_s)
      expect(MB::Sound::GraphNode.method_defined?(n)).to eq(false)
    end
  end

  it 'saves scene blocks of set commands, and refuses other blocks and goto Procs' do
    a = session
    within(a) {
      MB::Sound.track(:drone) { |c| c.tone.ramp }
      MB::Sound.scene(:gap) { MB::Sound.meter 2, 4 }
      MB::Sound.scene(:lift, others: :keep) { |_t|
        MB::Sound.bg :riser, MB::Sound.noise.at(0.12), fade: 0
      }
    }
    expect { io.dump(a.arrangement, name: 'x') }.to raise_error(io::DumpError, /scene :gap's block can't be saved: a scene block holds/)

    # As typed in the console or written in MB::Sound
    file = tmp_path('scene_blocks.rb')
    File.write(file, <<~RUBY)
      module MB::Sound
        scene(:gap) { meter 2, 4 }
        scene(:lift, others: :keep) { |_t|
          bg :riser, noise.at(0.12), fade: 0
        }
      end
    RUBY
    within(a) { load file }
    text = nil
    expect { text = io.dump(a.arrangement, name: 'x') }.not_to output.to_stderr
    expect(text).to include("scene(:gap) { meter 2, 4 }\nscene(:lift, others: :keep) { |_t|\n  bg :riser, noise.at(0.12), fade: 0\n}\n")

    b = session
    io.load(text, session: b)
    expect(stable(io.dump(b.arrangement, name: 'x'))).to eq(stable(text))
    within(b) { b.arrangement.go(:gap, on: :now) }
    3.times { b.process_buffer }
    expect(b.transport.meters.last.bar_length).to eq(1/2r)
    within(b) { b.arrangement.go(:lift, on: :now) }
    3.times { b.process_buffer }
    expect(b.instance_variable_get(:@players).values.map(&:name)).to include(:riser)

    # A block reading the code around it can't be saved: live_error raises
    # in scripts, and live, the scene is saved without it
    riser = MB::Sound.noise
    within(a) { MB::Sound.scene(:lift, others: :keep) { |_t| MB::Sound.bg :riser, riser } }
    expect { io.dump(a.arrangement) }.to raise_error(io::DumpError, /scene :lift's block can't be saved: it uses riser from the code around it/)
    allow(MB::Sound).to receive(:live?).and_return(true)
    expect { text = io.dump(a.arrangement, name: 'x') }.to output(/scene :lift's block can't be saved/).to_stderr
    expect(text).to include("# WARNING(graph-io): scene :lift's block was left out (it uses riser from the code around it)")
    expect(text).to include("scene :lift, others: :keep\n")
    allow(MB::Sound).to receive(:live?).and_call_original

    within(a) {
      MB::Sound.scene(:lift, others: :keep)
      MB::Sound.flow(play: false) { lift 1; goto ->(_f) { :next } }
    }
    expect { io.dump(a.arrangement) }.to raise_error(io::DumpError, /goto Proc/)
  end

  it 'loads only set commands and assignments' do
    expect { io.load(%(graph 1, kind: :set\n220.hz.ramp), session: session) }.to raise_error(io::LoadError, /:2: a set document holds set commands/)
    expect { io.load(%(graph 1, kind: :set\nscene(:a) { |t| 1 }), session: session) }.to raise_error(io::LoadError, /:2: a scene block holds assignments and the commands meter, bpm, turn/)
    expect { io.load(%(graph 1, kind: :set\nscene(:a) { play 220.hz }), session: session) }.to raise_error(io::LoadError, /a scene block holds/)
    expect { io.load(%(graph 1, kind: :set\nscene(:a) { bg(:x, 1.constant) { 2 } }), session: session) }.to raise_error(io::LoadError, /without blocks/)
    expect { io.load(%(graph 1, kind: :set\nmutes(:a, :b) { 2 }), session: session) }.to raise_error(io::LoadError, /mutes takes no block/)
    expect { io.load(%(graph 1, kind: :set\nmeter 7.5, 8), session: session) }.to raise_error(io::LoadError, /meter takes beats and a note unit/)
    expect { io.load(%(graph 1, kind: :set\nflow do\n  verse\nend), session: session) }.to raise_error(io::LoadError, /:3: verse: undefined section 'verse'/)
    expect { io.load(%(graph 1, kind: :set\nflow do\n  instance_exec 2\nend), session: session) }.to raise_error(io::LoadError, /never allowed/)
    expect { io.load(%(graph 1, kind: :set\nflow do\n  __form__ 2\nend), session: session) }.to raise_error(io::LoadError, /can't be a section name/)
    expect { io.load(%(graph 1, kind: :set\nflow do\n  goto ->(f) { :x }\nend), session: session) }.to raise_error(io::LoadError, /goto Procs are code/)
    s = session
    doc = io.load(%(graph 1, kind: :set\nmeter 7, 8\nquant 2\nmutes :g, :a), session: s)
    expect(s.transport.bar_length).to eq(7/8r)
    expect(s.arrangement.quant).to eq(2)
    expect(s.mute_groups).to eq({ g: [:a] })
    expect(doc.form).to be_nil
  end
end
