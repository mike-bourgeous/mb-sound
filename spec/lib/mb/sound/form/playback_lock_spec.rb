# The lock order between a song form's lock and the render lock (fixes-17;
# Form::Playback::Lock): a merge train's every-demo check froze in a
# deadlock ("No live threads left") when `go :section` seeked the playing
# flow while the scheduler launched a section.  The render thread, holding
# the render lock, committed the seek and waited for the form's lock; the
# scheduler held the form's lock in #begin_pass and waited for the render
# lock (Session#add of the section's tracks).  Seeks now take the form's
# lock without waiting and land at a later span when it is busy, as far
# past their target as they landed late.
RSpec.describe(MB::Sound::Form::Playback, 'and the render lock') do
  let(:out) { MB::Sound::NullOutput.new(channels: 1, sleep: :virtual, buffer_size: 800) }
  let(:session) do
    MB::Sound::Session.new(output: out, realtime: true, channels: 1, buffer_size: 800, master_gain: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
  end
  let(:set) { session.arrangement }

  after do
    @gate&.close
    session.close
    MB::Sound.rewind
  end

  # Waits for the block to be true, failing after +timeout+ seconds.
  def wait_for(what, timeout: 10)
    deadline = MB::U.clock_now + timeout
    until yield
      raise "timed out waiting for #{what}" if MB::U.clock_now > deadline
      Thread.pass
    end
  end

  def scheduler_thread
    session.instance_variable_get(:@scheduler).instance_variable_get(:@thread)
  end

  it 'lands a seek that comes while the scheduler launches a section late, aligned, and without a deadlock' do
    blocking = [false]
    building = Queue.new
    @gate = Queue.new
    gate = @gate
    set.track(:a) { |c| c.number * 0.001 }
    set.track(:b) { |c| # (a track starting builds its patch in the launch)
      if blocking[0]
        blocking[0] = false
        building << true
        gate.pop # (the scheduler waits here holding the form's lock)
      end
      c.number * 0.001
    }
    set.scene(:one, a: MB::Sound.seq(MB::Sound::C3).n1.loop)
    set.scene(:two, a: MB::Sound.seq(MB::Sound::C3).n1.loop, b: MB::Sound.seq(MB::Sound::D3).n1.loop)
    set.scene(:three, a: MB::Sound.seq(MB::Sound::E3).n1.loop)
    form = MB::Sound::Form.build { one 1; two 1; three 1 }
    MB::Sound::Session.with_context(session: session) { set.play_form(form, warm_up: false) }
    # (bars of 2 s: section :two's block runs half a bar ahead, at 1 s)
    blocking[0] = true
    t = Thread.new { MB::Sound::Internal.wait_audio(session, 1.5) }
    expect(building.pop(timeout: 20)).to eq(true) # (the scheduler is inside #begin_pass of :two)
    t.join(20)

    seeker = Thread.new { MB::Sound::Session.with_context(session: session) { session.seek(:three) } }
    deadlocked = seeker.join(10).nil?
    begin
      expect(deadlocked).to eq(false), 'the seek waited for the form lock under the render lock'
      seek = seeker.value
      expect(session.journal[seek.seq].status).to eq(:queued) # (the form's lock is busy: it waits for a later span)
      due_frame = session.frame

      # A few buffers render while the launch holds the lock: the seek waits
      t = Thread.new { MB::Sound::Internal.wait_audio(session, 0.1) }
      t.join(20)
      expect(session.journal[seek.seq].status).to eq(:queued)

      gate << true
      wait_for('the seek to land') {
        MB::Sound::Internal.wait_audio(session, 0.02)
        session.journal[seek.seq].status == :landed
      }
    ensure
      if deadlocked
        gate << true
        scheduler_thread&.kill # (its form lock is released, so the seek thread goes on)
        seeker.join(10)
      end
    end

    late = session.journal.changes.find { |e| e.kind == :late_seek }
    expect(late).not_to be_nil
    expect(late.data[:frames]).to be > 0
    landed = session.journal[seek.seq].lands
    expect(landed.frame - late.data[:frames]).to be >= due_frame

    # Aligned: the timeline is where an on-time landing at its due frame
    # would have put it by now (section :three starts at 2 whole notes)
    pos, frame = session.with_render_lock { [session.transport.position, session.frame] }
    per_frame = session.transport.whole_notes_per_frame(session.sample_rate)
    expect(pos).to be_within(per_frame).of(2 + (frame - (landed.frame - late.data[:frames])) * per_frame)
    expect(set.playback.section).to eq(:three)
  end

  it 'raises in check mode when a thread holding the render lock waits for the form lock' do
    set.track(:a) { |c| c.number * 0.001 }
    set.scene(:one, a: MB::Sound.seq(MB::Sound::C3).n1.loop)
    MB::Sound::Session.with_context(session: session) { set.play_form(MB::Sound::Form.build { one 2 }, warm_up: false) }
    pb = set.playback
    expect { session.with_render_lock { pb.history } }.to raise_error(MB::Sound::Form::Playback::LockOrderError, /render lock waited for a form's lock/)
    expect(session.with_render_lock { pb.try_hold.tap { pb.release_hold } }).to eq(true) # (without waiting: allowed)
    expect(pb.history).to eq([:one]) # (not under the render lock: allowed)
  end
end
