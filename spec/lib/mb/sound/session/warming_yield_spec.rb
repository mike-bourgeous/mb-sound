# A new Session's first play on the :low profile (fixes-19): the merge
# train saw an underrun right after `latency :low` in 4 of 4 console runs.
# The writer found room in the 11 ms queue, then waited 6-12 ms for the GVL
# while the first graph's warm-up worker (and the scope band's painter)
# ran whole timeslices: they yield to the render thread only once it is
# followed (UI::Yielding), and a new Session's render thread was followed
# only when a painter's frame saw it.  Now Session#start_thread follows it,
# and the warm-up worker names it when it joins.
#
# Here: realtime Sessions on miniaudio's null device at the :low profile,
# each first graph warmed on its background thread (as the console does),
# the writer's own trace measuring how long it waited for the GVL after it
# found room.  The spec process runs with Ruby's default 100 ms timeslice,
# so a warm-up that doesn't yield shows as tens of ms (20 ms measured
# before).  GC is off while each warm-up is measured: a collection holds
# the GVL whatever yields, and that is another matter.
RSpec.describe('MB::Sound::Session warm-ups on a new :low output', :aggregate_failures) do
  before { MB::Sound::Session::Warming.always = true } # (every add warms, not only the first of a kind)

  after do
    MB::Sound::Session::Warming.always = false
    MB::Sound.rewind
  end

  it 'yield the GVL to the render thread from its first buffer' do
    skip 'thread handovers are native-only (Valgrind serializes threads)' if defined?(SPEC_MEMCHECK) && SPEC_MEMCHECK
    rows = []
    4.times do |i|
      out = MB::Sound::DeviceOutput.new(channels: 2, backends: [:null], profile: :low, adaptive: false)
      session = MB::Sound::Session.new(output: out, realtime: true)
      session.warm_changes = true
      session.warm_background = true
      out.trace_start
      u0 = out.underruns
      n0 = session.warmed.length
      # (no collection while it is measured: a minor GC in this big spec
      # process takes 20-30 ms and holds the GVL whoever yields)
      GC.start
      GC.disable
      session.add((220 + i).hz.saw.lp4(800, resonance: 0.3).softclip.at(-20.db), name: :a)
      expect(MB::Sound::FastUI::GVLYield.priority).to equal(session.render_thread) if MB::Sound::UI::Yielding.available?
      wait_until!('the warm-up', timeout: 20) { session.warmed.length > n0 }
      GC.enable
      writes, _gaps = out.trace_drain
      back = writes.select { |w| w[3] > 0 }.map { |w| (w[4] - w[3]) / 1e6 }
      rows << { gvl_after_room_ms: back.max.to_f.round(2), underruns: out.underruns - u0, warm: session.warmed.last.to_s }
    ensure
      GC.enable
      session&.close
      out&.close
    end
    expect(rows.map { |r| r[:gvl_after_room_ms] }.max).to be < 5, rows.inspect
  end
end
