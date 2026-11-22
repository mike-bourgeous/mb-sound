RSpec.describe(MB::Sound::Session::Undo) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:buffer_size) { 800 }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true) }

  after { session.close }

  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    SpecBuffers.join(Array.new(frames / 800) { session.process_buffer[0].dup })
  end

  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v.round(4)] }
  end

  it 'undoes a replacement at the next bar, bringing back the same graph with a declick crossfade' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    old = session.instance_variable_get(:@players).values.first.input
    within { MB::Sound.bg(:x, 2.constant, at: :now) }
    run(800)

    step = within { MB::Sound.undo }
    expect(step.to_s).to eq('undo bg :x lands 2:1')
    data = run(96000)
    bar = 96000 - 1600
    expect(data[bar - 1]).to eq(2)
    expect(data[bar + 120]).to be_within(1e-6).of(1.5)
    expect(data[bar + 240]).to eq(1)
    expect(session.instance_variable_get(:@players).values.map(&:input)).to eq([old])
  end

  it 'undoes right away with at: :now, and redoes' do
    within { MB::Sound.bg(:x, 1.constant) }
    within { MB::Sound.bg(:x, 2.constant, at: :now) }
    run(800)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)

    step = within { MB::Sound.redo!(at: :now) }
    expect(step.label).to eq('bg :x')
    expect(run(1600)[-1]).to eq(2)
    expect(session.undo_steps.map(&:label)).to eq(['bg :x', 'bg :x'])
    expect(session.redo_steps).to eq([])
  end

  it 'cancels a change that has not landed yet, and redo queues it again' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    within { MB::Sound.bg(:x, 2.constant, fade: 0) } # next bar
    expect(session.queued(:x).length).to eq(1)

    step = within { MB::Sound.undo }
    expect(step.to_s).to eq('undo bg :x (cancelled)')
    expect(session.queued(:x)).to eq([])
    expect(session.journal.changes.map(&:status)).to include(:cancelled)

    within { MB::Sound.redo! }
    data = run(96000 * 2)
    expect(changes(data)).to eq([[0, 1], [96000 - 800, 2]])
  end

  it 'undoes a stop by resuming the stopped graph' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    within { MB::Sound.stop(:x, fade: 0) }
    expect(run(800).to_a.uniq).to eq([0])
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
    expect(session.stopped).to eq({})
  end

  it 'undoes swaps, putting the old clips back' do
    a = MB::Sound.seq(MB::Sound::C3).n1.loop
    b = MB::Sound.seq(MB::Sound::D3).n1.loop
    within { MB::Sound.bg(:n, a.number) }
    within { MB::Sound.swap(:n, b, at: :now) }
    expect(run(1600)[-1]).to eq(50)
    within { MB::Sound.undo }
    data = run(96000)
    expect(changes(data)).to eq([[0, 50], [96000 - 1600, 48]])
  end

  it 'undoes mutes and solos' do
    within { MB::Sound.bg(:x, 1.constant); MB::Sound.bg(:y, 2.constant) }
    within { MB::Sound.solo(:x) }
    expect(run(1600)[-1]).to eq(1)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(3)
    expect(session.strip_info[:soloed]).to eq([])
  end

  it 'undoes master effects by rebuilding the old chain from its block' do
    within { MB::Sound.bg(:x, 1.constant) }
    within { MB::Sound.master(at: :now) { |m| m * 2 } }
    within { MB::Sound.master(at: :now) { |m| m * 3 } }
    expect(run(1600)[-1]).to eq(3)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(2)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
  end

  it 'undoes a scene launch as one step, restoring the set state' do
    set = session.arrangement
    a1 = MB::Sound.seq(MB::Sound::C3).n1.loop
    a2 = MB::Sound.seq(MB::Sound::D3).n1.loop
    set.track(:a) { |c| c.number }
    set.track(:b) { |c| c.number * 100 }
    set.scene(:one, a: a1)
    set.scene(:two, a: a2, b: a1)
    within { MB::Sound.go(:one, at: :now) }
    run(800)
    within { MB::Sound.go(:two, at: :now) }
    expect(run(1600)[-1]).to eq(50 + 4800)

    within { expect(MB::Sound.changes).to eq(['1. go :one lands 1:1', '2. go :two lands 1:1.033']) }
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(48)
    expect(set.current_scene).to eq(:one)
    expect(set.tracks[:a].clip).to equal(a1)
  end

  it 'groups the commands of a scheduled block into one step' do
    within do
      MB::Sound.bg(:x, 1.constant)
      MB::Sound.at_bar(2) { MB::Sound.bg(:y, 2.constant); MB::Sound.bg(:z, 4.constant) }
    end
    run(96000 + 800)
    expect(session.undo_steps.map(&:label)).to eq(['bg :x', 'bar 2'])
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
  end

  it 'drops the oldest steps when they keep too many retired graphs alive' do
    stub_const('MB::Sound::Session::Undo::RETIRED_GRAPH_LIMIT', 3)
    within do
      MB::Sound.bg(:x, 0.constant)
      6.times { |i| MB::Sound.bg(:x, (i + 1).constant, at: :now) }
    end
    run(800)
    expect(session.retired_graphs.length).to be <= 3
    expect(session.undo_steps.length).to eq(3)
  end

  # undo-one-step-1 (the maintainer, 2026-11-22: "Having undo step back
  # only one step seems ideal"): a redefinition queued while an earlier one
  # still waits for its launch point supersedes it (Session#add), and undo
  # used to restore what was playing when the undone line ran, so lines
  # faster than their landings undid several redefinitions at once.  Undo
  # and redo now step through the journal's definitions one at a time,
  # whether or not a definition ever got to play.
  describe 'one step back after quick redefinitions' do
    # (the cutoffs of the graphs playing as :t)
    def playing
      session.instance_variable_get(:@players).values.select { |p| p.name == :t && p.current? }.map { |p|
        p.input.graph.grep(MB::Sound::GraphNode::Constant).map(&:constant).select { |c| c > 1000 }
      }.flatten
    end

    def bars(n)
      to = session.frame + (n * 96000).to_i
      session.process_buffer while session.frame < to
    end

    def define(cutoff, q: 1)
      MB::Sound.track(:t, q: q) { |clip| clip.hz.ramp.at(-20.db).filter(:lowpass, cutoff: cutoff, quality: 2) }
    end

    before do
      within do
        define(1200)
        MB::Sound.bg(:t, MB::Sound.seq(MB::Sound::A2).n1.loop)
      end
      bars(1.5) # (mid-bar: the redefinitions wait for their launch points)
    end

    after { MB::Sound.rewind }

    it 'lands the last of several redefinitions queued behind one for an earlier launch point, and undoes one at a time' do
      # (1201 lands on the next beat, 1202 and 1203 on bar 3: 1202 follows
      # 1201, carrying from its graph, and 1203, superseding 1202, follows
      # 1201 too; before, 1203 carried from 1200, which 1201 replaced
      # first, so it was dropped and 1201 played on)
      bars(1/8r) # (between beats)
      within do
        define(1201, q: 1/4r)
        expect(session.queued(:t).length).to eq(1)
        define(1202)
        define(1203)
      end
      bars(1)
      expect(playing).to eq([1203])

      within { MB::Sound.undo }
      bars(2)
      expect(playing).to eq([1202])
      within { MB::Sound.undo }
      bars(2)
      expect(playing).to eq([1201])
      within { 2.times { MB::Sound.redo! } }
      bars(2)
      expect(playing).to eq([1203])
    end

    [800, 367].each do |size|
      context "at #{size}-frame buffers" do
        let(:buffer_size) { size }

        before { within { [1201, 1202, 1203].each { |c| define(c) } } }

        it 'undoes and redoes one queued redefinition at a time before any lands' do
          expect(session.queued(:t).length).to eq(1) # (each superseded the one before)
          expect(session.undo_steps.map(&:label).last(3)).to eq(['track :t redefined'] * 3)

          within { MB::Sound.undo }
          expect(session.queued(:t).length).to eq(1)
          bars(0.25)
          expect(playing).to eq([1200])

          within { MB::Sound.undo }
          within { MB::Sound.redo! }
          bars(1)
          expect(playing).to eq([1202]) # (1203, undo 1202, undo 1201, redo 1202)
          expect(session.journal.changes.last.to_s).to match(/bg :t landed 3:1/) # (the re-queued rebuild, carrying from 1200)

          within { MB::Sound.undo }
          bars(2)
          expect(playing).to eq([1201])
          within { MB::Sound.undo }
          bars(2)
          expect(playing).to eq([1200])
          within { 3.times { MB::Sound.redo! } }
          bars(2)
          expect(playing).to eq([1203])
        end

        it 'undoes one redefinition at a time after the last one landed, and redoes them' do
          bars(2)
          expect(playing).to eq([1203])

          [1202, 1201, 1200].each do |want|
            within { MB::Sound.undo }
            bars(2)
            expect(playing).to eq([want])
          end
          [1201, 1202, 1203].each do |want|
            within { MB::Sound.redo! }
            bars(2)
            expect(playing).to eq([want])
          end
        end
      end
    end
  end

  it 'undoes a stop for now by queueing again the start it dropped, its graph kept in step meanwhile' do
    shared = 3.hz.lfo
    within do
      MB::Sound.bg(:o, shared * 0.01)
      MB::Sound.bg(:x, 1.constant)
    end
    run(48000)
    within do
      MB::Sound.bg(:x, shared * 0.5 + 2, at: MB::Sound.bar(4))
      MB::Sound.stop(:x, fade: 0)
    end
    expect(session.queued(:x)).to eq([])
    expect(session.undo_steps.last.to_s).to eq('stop :x lands 1:3')
    run(192_000)

    # (the dropped graph's branch of the shared LFO kept up while the undo
    # list held it: the Tee stays in lockstep, not a second behind)
    tee = ObjectSpace.each_object(MB::Sound::GraphNode::Tee).find { |t| t.original_source.equal?(shared) }
    expect(tee.branches.map { |b| b.reader&.length || 0 }.max).to eq(0)

    within { MB::Sound.undo }
    expect(session.queued(:x).map(&:to_s)).to eq(['restore :x lands 4:1 (queued)', 'bg :x lands 4:1 (queued)'])
    data = run(96000)
    expect(data[-1]).to be > 1.5 # (the dropped graph plays from bar 4)
  end
end
