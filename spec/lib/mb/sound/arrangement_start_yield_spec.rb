# A cold `start` of a demo (demo-cold-start-1): `demo` opens the output and
# its master chain and buses start the render thread, so the session writes
# silence while `start` warms the form up and builds the first section on
# the console thread.  That thread didn't hand the GVL over: the render
# thread waited up to 110 ms for it on dummy JACK (an underrun before the
# landing, which raised the adaptive queue).  Arrangement#play_form now runs
# both inside Internal.yielding_to_render.
#
# Here: a realtime Session on miniaudio's null device at the :low profile,
# its render thread running, a form whose only track spends 30 ms of Ruby in
# every build.  The spec process has Ruby's default 100 ms timeslice, so a
# thread that doesn't yield holds the GVL for each whole build.  GC is off
# while it is measured, and the warm-up's closing GC.start does nothing (a
# collection holds the GVL whoever yields).
RSpec.describe(MB::Sound::Arrangement, '#play_form on a running realtime session', :aggregate_failures) do
  after { MB::Sound.rewind }

  it 'hands the GVL to the render thread while it warms up and builds the first section' do
    skip 'thread handovers are native-only (Valgrind serializes threads)' if defined?(SPEC_MEMCHECK) && SPEC_MEMCHECK
    skip 'needs fast_ui (UI::Yielding)' unless MB::Sound::UI::Yielding.available?

    # (silence for an underrun: repeat concealment holds queued frames
    # while it lands, and the writer then waits for room however the GVL
    # goes)
    GC.start
    out = MB::Sound::DeviceOutput.new(channels: 2, backends: [:null], profile: :low, adaptive: false, conceal: false)
    session = MB::Sound::Session.new(output: out, realtime: true, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    set = session.arrangement
    builds = 0
    spin = ->(seconds) { t = MB::U.clock_now; n = 0; n += 1 while MB::U.clock_now - t < seconds; n }
    set.track(:busy) { |c| builds += 1; spin.(0.03); c.tone.sine.at(-30.db) }
    set.scene(:one, busy: MB::Sound.seq(MB::Sound::C3).n4.loop)
    # (a master chain, as a demo's set has: the render thread then keeps
    # writing while nothing plays; an idle session with none stops writing)
    session.master { |sig| sig * 1.0 }
    session.ensure_running
    wait_until!('the render thread writing', timeout: 10) { out.stats[:frames_written] > 4 * session.buffer_size }

    out.trace_start
    out.trace_drain
    GC.disable
    # (the warm-up's own GC.start holds the GVL whoever yields: another
    # matter, left out here)
    allow(GC).to receive(:start)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    t1 = nil
    expect {
      MB::Sound::Session.with_context(session: session) { set.play_form(MB::Sound::Form.build { one 1 }, warm_up: true) }
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    }.to output(/Warmed up 1 track/).to_stdout
    wait_until!('the landing', timeout: 10) { session.players.key?(:busy) }
    GC.enable
    writes, _gaps = out.trace_drain
    during = writes.select { |w| w[0] >= t0 && w[0] <= t1 }
    apart = during.each_cons(2).map { |a, b| (b[0] - a[1]) / 1e6 }
    back = during.select { |w| w[3] > 0 }.map { |w| (w[4] - w[3]) / 1e6 }

    expect(builds).to be >= 3 # (the warm-up's two builds and the live one)
    expect(during.length).to be > 10
    expect(apart.max).to be < 15, "the render thread wrote #{apart.max&.round(1)} ms apart (a 5.3 ms period)"
    expect(back.max.to_f).to be < 5, "the render thread waited #{back.max.to_f.round(1)} ms for the GVL after it found room"
  ensure
    GC.enable
    session&.close
    out&.close
  end
end
