RSpec.describe('MB::Sound#beats (evolving rhythms)', :aggregate_failures) do
  def groove(seed: 5, energy: 0.5, hold: 2, **opts)
    MB::Sound.beats(16, hold: hold, swing: 0.54, energy: energy, seed: seed, **opts) do
      kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], drift: 0.12, energy: false
      clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.9
      snare [0, 0, 0, 0.1, 0, 0, 0.15, 0, 0, 0.1, 0, 0, 0, 0.2, 0, 0.25], drift: 0.2, level: 0.55
      hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.75
      open_hat [0, 0, 0.9, 0] * 4, drift: 0.3, level: 0.7
      fill every: 8, snare: 0.7, low_tom: 0.4
    end
  end

  # Hits of +clip+'s cycle as [note, step] pairs.
  def hits(clip, cycle)
    clip.events_for(cycle).map { |e| [e.value, (e.start * 16).floor] }.sort
  end

  it 'makes a looping generator clip whose values are its rows\' drum notes' do
    g = groove
    expect(g).to be_looping
    expect(g.length).to eq(1)
    expect(g.values).to eq([36, 39, 38, 42, 46, 45])
    expect(g.events_for(0)).not_to be_empty
    expect(MB::Sound.tr909(g)).to be_a(MB::Sound::GraphNode)
  end

  it 'computes any cycle the same cold as in order' do
    warm = groove
    list = (0..130).map { |c| warm.events_for(c) }
    [129, 64, 0, 7, 33].each do |c|
      expect(groove.events_for(c)).to eq(list[c]), "cycle #{c}"
    end
  end

  it 'holds each bar for hold: cycles, keeps anchors, and drifts the rest' do
    g = groove
    expect(hits(g, 0)).to eq(hits(g, 1))
    expect(hits(g, 2)).to eq(hits(g, 3))
    expect((0..40).map { |c| hits(g, c) }.uniq.length).to be > 5
    (0..40).each do |c|
      kicks = hits(g, c).select { |n, _| n == 36 }.map(&:last)
      expect(kicks).to include(0, 4, 8, 12)
      claps = hits(g, c).select { |n, _| n == 39 }.map(&:last)
      expect(claps).to include(4, 12)
    end
  end

  it 'only adds hits as the energy rises, and thins everything but fills at low energy' do
    levels = [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0]
    ((0..12).to_a - [6, 7]).each do |c| # (not the fill's hold block)
      sets = levels.map { |e| hits(groove(energy: e), c) }
      sets.each_cons(2) { |a, b| expect(a - b).to be_empty, "cycle #{c}" }
      # At 0 only the kick (energy: false) plays
      expect(sets.first.map(&:first).uniq).to eq([36])
    end
  end

  it 'fills the last beat of every 8th cycle' do
    g = groove(hold: 1)
    toms = (0..23).select { |c| hits(g, c).any? { |n, _| n == 45 } }
    expect(toms - [7, 15, 23]).to be_empty
    expect(toms).not_to be_empty
    hits(g, 7).select { |n, _| n == 45 }.each { |_, s| expect(s).to be >= 12 }
  end

  it 'grows a fill denser and longer with the energy when the fill follows it (energy: true)' do
    energized = ->(e, seed: 5) {
      MB::Sound.beats(16, hold: 1, energy: e, seed: seed) do
        kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], energy: false
        fill every: 4, energy: true, snare: 0.6, low_tom: 0.4
      end
    }
    toms = ->(g, c) { hits(g, c).reject { |n, _| n == 36 } }
    # As written at 0.5: the same fill as one that ignores the energy
    plain = MB::Sound.beats(16, hold: 1, energy: 0.5, seed: 5) do
      kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], energy: false
      fill every: 4, snare: 0.6, low_tom: 0.4
    end
    half = energized.(0.5)
    (0..40).each { |c| expect(hits(half, c)).to eq(hits(plain, c)), "cycle #{c}" }

    levels = [0.0, 0.2, 0.5, 0.8, 1.0]
    clips = levels.map { |e| energized.(e) }
    fills = (0..39).select { |c| (c + 1) % 4 == 0 }
    counts = clips.map { |g| fills.sum { |c| toms.(g, c).length } }
    expect(counts.first).to eq(0) # (fades out at 0)
    expect(counts.each_cons(2).all? { |a, b| a <= b }).to be(true), counts.inspect
    expect(counts.last).to be > counts[2] * 1.5
    fills.each do |c|
      # Only adds hits as the energy rises
      clips.map { |g| toms.(g, c) }.each_cons(2) { |a, b| expect(a - b).to be_empty, "cycle #{c}" }
      # Longer: at 1 the fill covers the last half bar, at 0.5 the last beat
      expect(toms.(clips.last, c).map(&:last).min || 8).to be >= 8
      expect(toms.(half, c).map(&:last).min || 12).to be >= 12
    end
    expect(fills.flat_map { |c| toms.(clips.last, c).map(&:last) }.min).to be < 12
    expect(((0..39).to_a - fills).flat_map { |c| toms.(clips.last, c) }).to be_empty
    expect(MB::Sound::Generative::Beats.fill_span(4, 1.0, 16)).to eq(8)
    expect(MB::Sound::Generative::Beats.fill_span(4, 0.0, 16)).to eq(2)
    expect(MB::Sound::Generative::Beats.fill_span(12, 1.0, 16)).to eq(16)
    expect { MB::Sound.beats { kick [1]; fill every: 4, energy: 1, snare: 0.5 } }.to raise_error(ArgumentError, /energy: is true or false/)
  end

  it 'swings odd steps and takes groove velocities' do
    g = MB::Sound.beats(8, step: 1.n8, swing: 0.6, groove: [1.0, 0.5], humanize: 0, seed: 1) { hat [1] * 8 }
    ev = g.events_for(0)
    expect(ev.map(&:start)).to eq((0...8).map { |s| s * 1r / 8 + (s.odd? ? 1r / 40 : 0) })
    expect(ev.map(&:velocity)).to eq([1.0, 0.5] * 4)
  end

  it 'plays melodic rows walking a field\'s scale notes (rhythm)' do
    h = MB::Sound.scale(:dorian, :d).weights
    r = MB::Sound.rhythm(h.over(38..62), [1, 0, 0.5, 0.5] * 4, hold: 2, seed: 2)
    notes = (0..20).flat_map { |c| r.events_for(c).map(&:value) }
    expect(notes - MB::Sound.scale(:dorian, :d).notes(38..62).map { |n| n.respond_to?(:number) ? n.number : n }).to be_empty
    expect(notes.uniq.length).to be > 4
    # A held bar repeats its line (velocities vary a little)
    line = ->(c) { r.events_for(c).map { |e| [e.start, e.value] } }
    expect(line.(1)).to eq(line.(0))
    expect(line.(2)).not_to eq(line.(0))
  end

  it 'reads a knob energy at each cycle\'s decision point' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 1, buffer_size: 800, realtime: false, raise_errors: true, master_gain: 1)
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.knob :energy, 0.0
      g = groove(energy: MB::Sound.knob(:energy), hold: 1)
      expect(g).to be_steered
      MB::Sound.bg(:d, g.number * 0.01 + g.trigger, on: :now)
      MB::Sound.turn :energy, 1.0, smooth: 0, at: MB::Sound.bar(2)
      Array.new(4 * 120) { s.process_buffer }
      # Cycle 1 decided at 0.75 (before the turn), cycle 2 at 1.75 (after)
      expect(hits(g, 1).map(&:first).uniq).to eq([36])
      expect(hits(g, 2).length).to be > 12
    }
  ensure
    s&.close
  end

  it 'saves in graph documents with its knob, loading the rows without trust' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false, channels: 1)
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.knob :energy, 0.7
      g = MB::Sound.beats(16, energy: MB::Sound.knob(:energy), hold: 2, seed: 3) {
        kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
        hat euclid(10, 16), mutate: 0.5
        row :bass, [1, 0, 0.5, 0] * 4, note: 36
        fill every: 4, snare: 0.6
      }
      lead = MB::Sound.motifs(MB::Sound.scale(:dorian, :d).weights, 8, density: MB::Sound.knob(:energy), seed: 4)
      graph = MB::Sound.tr909(g) + lead.synth { |v| v.hz.sine * v.env(0.01, 0.1, 0.5, 0.1) }
      doc = MB::Sound::GraphIO.dump(graph, name: :steer)
      expect(doc).to include('knob :energy, 0.7')
      expect(doc).to include('energy: energy').and include('density: energy')
      loaded = MB::Sound::GraphIO.load(doc)
      expect(loaded).to be_a(MB::Sound::GraphNode)
      # The same samples as the graph saved (both knobs rest at 0.7)
      a = SpecBuffers.join(Array.new(120) { graph.sample(800).dup })
      b = SpecBuffers.join(Array.new(120) { loaded.sample(800).dup })
      expect(a.abs.max).to be > 0.1
      expect(b).to eq(a)
    }
  ensure
    s&.close
  end

  it 'explains mistakes' do
    expect { MB::Sound.beats { snair [1] } }.to raise_error(NoMethodError, /did you mean :snare/)
    expect { MB::Sound.beats { kick [2] } }.to raise_error(ArgumentError, /probabilities from 0 to 1/)
    expect { MB::Sound.beats { row :bass, [1] } }.to raise_error(ArgumentError, /need note: or notes:/)
    expect { MB::Sound.beats(energy: 3) { kick [1] } }.to raise_error(ArgumentError, /energy/)
    expect { MB::Sound.beats { fill every: 8, snare: 0.5; fill every: 4, snare: 0.5 } }.to raise_error(ArgumentError, /Only one fill/)
  end
end
