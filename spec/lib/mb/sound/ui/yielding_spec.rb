require_relative '../../../../support/ui_helpers'

RSpec.describe(MB::Sound::UI::Yielding) do
  let(:gy) { MB::Sound::FastUI::GVLYield }

  after { described_class.close }

  it 'registers a thread with one idempotent call, names the render thread, and drops threads that end' do
    render = Thread.new { sleep }
    worker = Thread.new { sleep }
    expect(described_class.join(worker, render: render)).to eq(true)
    expect(described_class.join(worker, render: render)).to eq(true)
    expect(gy.yielders).to eq([worker])
    expect(gy.priority).to equal(render)
    expect(described_class).to be_active
    worker.kill.join
    expect(wait_until { gy.yielders.empty? }).to eq(true) # (an ended thread leaves by itself)
    described_class.leave(worker)
    expect(gy.priority).to be_nil # (let go with no yielder left)
    expect(described_class).not_to be_active
    expect(described_class.follow(nil)).to be_nil
  ensure
    render&.kill&.join
    worker&.kill&.join
  end

  describe 'the painter (FrameRate#yield_to_render; ui-perf-2)' do
    let(:screen) {
      Class.new {
        include MB::Sound::UI::FrameRate
        attr_accessor :attached, :reader
        def initialize
          @attached = @reader = @yield_render = nil
        end
      }.new
    }

    it 'joins the painter (and with .input the input thread) when the followed render thread appears, allocates nothing while it stays, and leaves when it goes' do
      render = Thread.new { sleep }
      input = Thread.new { sleep }
      screen.instance_variable_set(:@reader, input)
      session = Struct.new(:render_thread).new(nil)
      screen.attached = session
      was_input = described_class.input
      described_class.input = true
      screen.send(:yield_to_render)
      expect(gy.yielders).to eq([])
      session.render_thread = render
      screen.send(:yield_to_render)
      expect(gy.yielders).to contain_exactly(Thread.current, input)
      expect(gy.priority).to equal(render)
      screen.send(:yield_to_render)
      a = GC.stat(:total_allocated_objects)
      i = 0
      while i < 1000
        screen.send(:yield_to_render)
        i += 1
      end
      expect(GC.stat(:total_allocated_objects) - a).to be <= 1 # (the measurement's own; 0 a call)
      render.kill.join
      screen.send(:yield_to_render) # (a dead render thread: stop yielding)
      expect(gy.yielders).to eq([])
      expect(gy.priority).to be_nil
    ensure
      described_class.input = was_input
      screen.send(:stop_yielding)
      render&.kill&.join
      input&.kill&.join
    end

    it 'does nothing with Yielding.painter false' do
      render = Thread.new { sleep }
      screen.attached = Struct.new(:render_thread).new(render)
      was = described_class.painter
      described_class.painter = false
      screen.send(:yield_to_render)
      expect(gy.yielders).to eq([])
    ensure
      described_class.painter = was
      render&.kill&.join
    end
  end

  it 'logs late handovers with the yielder\'s Ruby frames (GVLYield.late_log, a diagnostic)' do
    skip 'handover timing is native-only (Valgrind serializes threads)' if defined?(SPEC_MEMCHECK) && SPEC_MEMCHECK
    expect(gy.late_log(true)).to be_an(Array)
    stop = false
    render = Thread.new { sleep 0.002 until stop }
    busy = Thread.new { Numo::DFloat.new(2_000_000).rand.sort until stop } # (a long C call: no interrupt check)
    expect(described_class.join(busy, render: render)).to eq(true)
    expect(wait_until { gy.stats[:kicks] > 0 }).to eq(true)
    s0 = gy.stats[:late_1ms]
    wait_until(timeout: 10) { gy.stats[:late_1ms] > s0 + 2 }
    log = gy.late_log
    expect(log).not_to be_empty, "#{gy.stats.inspect} #{s0}"
    at, late, thread, frames = log.first
    expect(at).to be_a(Float)
    expect(late).to be > 0.001
    expect(thread).to equal(busy)
    expect(frames.flatten.join(' ')).to include('yielding_spec.rb')
  ensure
    gy.late_log(false)
    stop = true
    busy&.join
    render&.join
  end

  it 'does nothing (saying so once) without the extension, or when off' do
    allow(described_class).to receive(:available?).and_return(false)
    described_class.instance_variable_set(:@said, false)
    expect { expect(described_class.join(Thread.current)).to eq(false) }.to output(/no GVLYield/).to_stderr
    expect { described_class.join(Thread.current) }.not_to output.to_stderr
    expect(described_class.stats).to eq({})
    expect(described_class.leave(Thread.current)).to be_nil
    allow(described_class).to receive(:available?).and_call_original
    was = described_class.on
    described_class.on = false
    expect(described_class.join(Thread.current)).to eq(false)
    expect(gy.yielders).to eq([])
  ensure
    described_class.on = was
  end

  # A stand-in render thread waking every 128 frames at 48 kHz (375 times a
  # second) while a registered thread runs Ruby without blocking: the
  # render thread gets the GVL within the bound, and the busy thread keeps
  # making progress
  it 'hands the GVL from a busy registered thread to a render thread waking on a timer, and the busy thread still runs' do
    period = 128 / 48000.0
    late = []
    stop = false
    go = Queue.new
    render = Thread.new do
      go.pop
      until stop
        t = MB::U.clock_now
        sleep period
        late << MB::U.clock_now - t - period
        x = 0
        2000.times { x += 1 } # (a buffer's work while holding the GVL)
      end
    end
    work = 0
    busy = Thread.new do
      go.pop
      a = (1..500).to_a
      until stop
        a.map { |v| v * 2 }
        work += 1
      end
    ensure
      described_class.leave
    end
    expect(described_class.join(busy, render: render)).to eq(true)
    expect(wait_until { gy.stats[:kicks] > 0 }).to eq(true)
    2.times { go << true }
    sleep 0.4
    stop = true
    [render, busy].each(&:join)
    late = late.sort
    p95 = late[(late.length * 0.95).floor]
    expect(described_class.stats[:yields]).to be > 0 unless SPEC_MEMCHECK # (Valgrind serializes threads)
    # (without yielding each wake waits out the busy thread's timeslice,
    # 10-100 ms; Valgrind serializes threads)
    expect(p95).to be < 0.003 unless SPEC_MEMCHECK
    expect(work).to be > 100 # (the busy thread was not starved)
  end
end
