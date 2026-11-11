# RSpec (core 3.13.6, expectations 3.13.5) crashes its formatters when an
# :aggregate_failures example that already failed has two after-hook errors:
# core joins them into a RSpec::Core::MultipleExceptionError that is never
# raised, so its backtrace is nil, and the aggregate failure's
# MultipleExpectationsNotMetError#format_backtrace calls nil.map
# (omnibus19: playback_end_spec.rb:42 on the Linux desktop, two failed
# expectations plus the render budget's and another guard's after hooks;
# spec:parallel lost that process's JSON report, 483 and 711 examples
# uncounted).  A joined error takes its first error's backtrace (or where it
# was made) so every formatter can print it.  Remove when RSpec fixes it
# (repro: two raising after hooks under :aggregate_failures with two failed
# expectations, --format json).
module MultipleExceptionBacktrace
  def initialize(*exceptions)
    super
    set_backtrace(all_exceptions.filter_map(&:backtrace).first || caller) if backtrace.nil?
  end
end

RSpec::Core::MultipleExceptionError.prepend(MultipleExceptionBacktrace)
