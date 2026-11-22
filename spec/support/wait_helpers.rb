# Waiting for a condition in specs (every example includes WaitHelpers;
# spec_helper).  Moved out of UIHelpers in fixes-18, so specs that don't
# load the UI helpers (device and JACK specs, which had silent copies of
# their own) use the same failing form.
module WaitHelpers
  # The default timeout of #wait_until and #wait_until! (seconds), and
  # what every timeout is multiplied by under Valgrind (rake memcheck runs
  # Ruby 20-50x slower; a longer timeout only costs time when a wait fails).
  WAIT_TIMEOUT = 5
  WAIT_MEMCHECK_SCALE = SPEC_MEMCHECK ? 12 : 1

  # Waits up to +timeout+ seconds for the block to be truthy; returns its
  # last value (falsy after a timeout: use it in an expectation, `expect(
  # wait_until { ... }).to eq(true), why`, or call #wait_until! instead;
  # a bare `wait_until { }` statement fails spec_hygiene_spec, since its
  # timeout went unnoticed: fixes-17, perf_spec's ack wait always ran out
  # its 5 s).  It checks every +poll+ seconds, and returns the value it saw
  # true, not a second reading (a passing condition, e.g. audio queued
  # while a device drains it, may be false again by then).  Spec files
  # don't define their own (spec_hygiene_spec; fixes-18: seven device and
  # JACK files had silent copies).  Timeouts scale by WAIT_MEMCHECK_SCALE.
  def wait_until(timeout: WAIT_TIMEOUT, poll: 0.01)
    deadline = MB::U.clock_now + timeout * WAIT_MEMCHECK_SCALE
    while true
      value = yield
      return value if value || MB::U.clock_now > deadline

      sleep poll
    end
  end

  # Raised by #wait_until! when its condition isn't met in time.
  class WaitTimeout < RuntimeError; end

  # #wait_until that fails: raises WaitTimeout naming +what+ (else the
  # block's line) if the block isn't truthy within +timeout+ seconds.
  # Returns the block's value.
  def wait_until!(what = nil, timeout: WAIT_TIMEOUT, poll: 0.01, &block)
    value = wait_until(timeout: timeout, poll: poll, &block)
    return value if value

    where = block.source_location&.then { |f, l| "#{File.basename(f)}:#{l}" }
    raise WaitTimeout, "timed out after #{timeout * WAIT_MEMCHECK_SCALE} s waiting for #{what || "the block at #{where}"}"
  end
end
