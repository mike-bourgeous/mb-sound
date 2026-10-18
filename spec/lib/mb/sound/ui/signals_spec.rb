require 'mb/sound'

# Chained SIGWINCH handlers (UI::Signals): screens wrap the handler before
# them, and Reline's handler calls whatever handler Reline replaced most
# recently (reline 0.7 io/ansi.rb reads @old_winch_handler when it runs), so
# a screen that wrapped Reline's handler and then got wrapped by Reline's
# next set_winch_handler made a cycle: SystemStackError in tiles_spec on
# the Mac (2026-10-18).  Wrappers from Signals.handler ignore re-entrant
# calls, which ends any such cycle after one round.
RSpec.describe(MB::Sound::UI::Signals, :aggregate_failures) do
  let(:signals) { described_class }

  # Reline's set_winch_handler and deprep, as in reline 0.7's ANSI IO.
  let(:fake_reline) {
    Class.new {
      attr_reader :calls

      def initialize = @calls = 0

      def set_winch_handler
        @old_winch_handler = Signal.trap('WINCH') do |arg|
          @calls += 1
          @old_winch_handler.call(arg) if @old_winch_handler.respond_to?(:call)
        end
      end

      def deprep
        Signal.trap('WINCH', @old_winch_handler) if @old_winch_handler
      end
    }.new
  }

  around do |ex|
    saved = Signal.trap('WINCH', 'DEFAULT')
    ex.run
  ensure
    Signal.trap('WINCH', saved || 'DEFAULT')
  end

  # Wraps the handler in place as Tiles#install_signals does, with
  # +maker+ building the wrapper.  Returns [wrapper, old, counter].
  def screen_wrap(maker)
    count = [0]
    old = nil
    w = maker.call { |sig| count[0] += 1; old.call(sig) if old.respond_to?(:call) }
    old = signals.chain('WINCH', w)
    [w, old, count]
  end

  def deliver
    Process.kill('WINCH', Process.pid)
    sleep 0.05 # (the main thread runs the trap between instructions)
  end

  it 'loops with a plain wrapper around Reline handlers, and not with Signals.handler' do
    fake_reline.set_winch_handler # R1: Reline's prompt
    w, _old, count = screen_wrap(->(&b) { proc(&b) }) # a screen wraps R1 (old style)
    fake_reline.set_winch_handler # the next prompt: R2 saves W; R1 now calls W too
    expect { w.call('WINCH') }.to raise_error(SystemStackError)

    Signal.trap('WINCH', 'DEFAULT')
    reline = fake_reline.class.new
    reline.set_winch_handler
    _w, _old, count = screen_wrap(->(&b) { signals.handler(&b) })
    reline.set_winch_handler
    deliver
    expect(count[0]).to be_between(1, 2) # (W directly via R2, and once more where R1 comes back to it at most)
    expect(reline.calls).to be >= 2
  end

  it 'survives screens installed twice and restored out of order, with WINCH in between' do
    reline = fake_reline
    reline.set_winch_handler
    a, a_old, ca = screen_wrap(->(&b) { signals.handler(&b) })
    reline.set_winch_handler
    b, b_old, cb = screen_wrap(->(&b) { signals.handler(&b) })
    deliver
    expect([ca[0], cb[0]]).to all(be >= 1)
    # Out of order: a leaves first (b's wrapper is in place, so it stays)
    expect(signals.unchain('WINCH', a, a_old)).to eq(false)
    reline.deprep
    reline.set_winch_handler
    deliver
    expect(signals.unchain('WINCH', b, b_old)).to eq(false) # (Reline's is on top now)
    reline.deprep
    deliver
    expect(signals.ours?(a)).to eq(true)
    expect(signals.ours?(proc {})).to eq(false)
  end
end
