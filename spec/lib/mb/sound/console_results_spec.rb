# Journal entries from stop/panic/forget, launch points on stop/outro, and
# panic as the scheduler's reset (maintainer decisions 2026-10-13;
# research-api-surface P9).
RSpec.describe('console command results') do
  # 120 BPM at 48kHz: one bar is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:out) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, buffer_size: 800, realtime: false) }

  after { session.close }

  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    SpecBuffers.join(Array.new(frames / 800) { session.process_buffer[0].dup })
  end

  describe '#stop and #outro' do
    it 'stop takes launch points and returns the queued entry' do
      within { MB::Sound.bg(:a, 1.constant) }
      run(800)
      e = within { MB::Sound.stop(:a, on: :bar, fade: 0) }
      expect(e.to_s).to eq('stop :a lands 2:1 (queued)')
      data = run(96000 * 2)
      expect(data[96000 - 800 - 1]).to eq(1)
      expect(data[96000 - 800]).to eq(0)
      expect(session.journal[e.seq].to_s).to eq('stop :a landed 2:1')
    end

    it 'stop takes in: and at:' do
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.bg(:b, 1.constant, on: :now)
      end
      e = within { [MB::Sound.stop(:a, in: 1.beat, fade: 0), MB::Sound.stop(:b, at: MB::Sound.bar(2), fade: 0)] }
      expect(e.map(&:to_s)).to eq(['stop :a lands 1:2 (queued)', 'stop :b lands 2:1 (queued)'])
    end

    it 'outro takes launch points' do
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.bg(:b, 1.constant, on: :now)
      end
      run(800)
      entries = within { MB::Sound.outro(on: 2, fade: 0) }
      expect(entries.map(&:to_s)).to eq(['stop :a lands 3:1 (queued)', 'stop :b lands 3:1 (queued)'])
    end

    it 'inside a scheduled block, counts launch points from the block' do
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.at_bar(2) { MB::Sound.stop(:a, in: 1.beat, fade: 0) }
      end
      data = run(96000 * 2)
      expect(data[96000 + 24000 - 1]).to eq(1)
      expect(data[96000 + 24000]).to eq(0)
    end
  end

  describe '#forget' do
    it 'returns journal entries and can be undone' do
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.bg(:b, 1.constant, on: :now)
        MB::Sound.stop(:a, :b, fade: 0)
      end
      expect(session.stopped.keys).to eq([:a, :b])

      e = within { MB::Sound.forget(:a) }
      expect(e.to_s).to eq('forget :a landed 1:1')
      expect(session.stopped.keys).to eq([:b])

      within { MB::Sound.undo(on: :now) }
      expect(session.stopped.keys).to contain_exactly(:a, :b)

      expect(within { MB::Sound.forget }.map(&:name)).to contain_exactly(:a, :b)
      expect(session.stopped).to be_empty
      expect(within { MB::Sound.forget }).to eq([])
    end
  end

  describe '#panic' do
    it 'cancels scheduled blocks and waiting changes, saying so' do
      ran = false
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.at_bar(3) { ran = true }
        MB::Sound.mute(:a, at: MB::Sound.bar(2))
      end
      run(800)

      expect(MB::Sound).to receive(:warn).with('panic: stopped 1 player; cancelled 1 queued change; cancelled 1 scheduled block (at_bar 3)')
      entries = within { MB::Sound.panic }
      expect(entries.map { |e| [e.kind, e.name, e.status] }).to eq([[:stop, :a, :landed], [:mute, :a, :cancelled]])

      run(96000 * 3)
      expect(ran).to eq(false)
      expect(session.scheduled).to be_empty
      expect(session.queued).to be_empty
    end

    it 'prints one line even when nothing was scheduled' do
      within { MB::Sound.bg(:a, 1.constant) }
      run(800)
      expect(MB::Sound).to receive(:warn).with('panic: stopped 1 player').once
      within { MB::Sound.panic }
    end

    it 'stops a song form' do
      within do
        MB::Sound.scene(:verse, others: :keep) { }
        MB::Sound.flow { verse 1; verse 1; verse 1 }
      end
      run(800)
      expect(session.arrangement.playback.ended?).to eq(false)

      expect(MB::Sound).to receive(:warn).with(/\Apanic: stopped 0 players; stopped the song form/)
      within { MB::Sound.panic }
      expect(session.arrangement.playback.ended?).to eq(true)
      expect(session.scheduled.reject { |h| h.owner == :take }).to be_empty
    end
  end

  describe 'in a take' do
    it 'replays a panic without cancelling the lines after it' do
      lines = {
        0 => ['bg :a, 0.25.constant', 'at_bar(3) { bg :late, 0.5.constant }'],
        150 => ['panic'],
        200 => ['bg :b, 0.125.constant'],
      }
      b = MB::Sound::Take.console_binding
      t = MB::Sound::Take.new(session: session)
      live = []
      allow(MB::Sound).to receive(:warn)
      360.times do |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
        live << session.process_buffer[0].dup
      end
      live = SpecBuffers.join(live)
      expect(live[149 * 800]).to eq(0.25)
      expect(live[201 * 800]).to eq(0.125)
      expect(live[-1]).to eq(0.125) # the at_bar(3) block was cancelled

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved the take/).to_stdout
      load path
      out = []
      MB::Sound::Take::Replay.last.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
      out = SpecBuffers.join(out)
      # (The timeline pauses between the panic and the next bg, so the
      # replay plays b right after the panic: compare what played)
      expect(out[0]).to eq(0.25)
      expect(out[-1]).to eq(0.125)
      expect(out.to_a.uniq - [0.0]).to eq([0.25, 0.125]) # the at_bar(3) block stayed cancelled
    end
  end

  describe 'the scheduler reset on a realtime session' do
    let(:session) { MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: true), transport: transport, buffer_size: 800, realtime: true) }

    it 'replaces a scheduler thread stuck in a block' do
      stuck = Queue.new
      later = Queue.new
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.at_bar(1, beat: 2) { stuck << :in; sleep }
      end
      expect(stuck.pop(timeout: 5)).to eq(:in)

      report = session.reset_scheduler(wait: 0.05)
      expect(report[:restarted]).to match(/the block for bar 1 beat 2 had run [\d.]+ s; stopped it and started a new scheduler thread/)

      # The new thread runs later blocks
      within { MB::Sound.at_bar(2) { later << :ran } }
      expect(later.pop(timeout: 10)).to eq(:ran)
    end
  end
end
