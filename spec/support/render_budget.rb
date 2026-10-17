# Caps the audio each example renders to unpaced NullOutputs (sleep: false
# or :virtual), so a realtime Session spinning on one (render thread
# writing as fast as it can while the example waits by wall clock) fails
# with a clear message instead of eating CPU and, with an output that keeps
# buffers, memory (monitor_trim_spec once grew a worker to 22 GB; see
# design/notes/audio_io.md).
#
# The default budget is RenderBudget::DEFAULT_SECONDS of audio per example
# (all unpaced NullOutputs together, any thread).  An example that really
# renders more says so with a reason:
#
#     it 'plays the whole song', render_budget: { seconds: 300, reason: 'four-minute form' } do
#
# Past the budget, NullOutput#write raises RenderBudget::Exceeded (on the
# render thread too, which stops a spinning Session), and the example fails
# afterwards even if the raise was rescued.  MB_SOUND_RENDER_BUDGET=report
# prints the examples over budget at exit instead of failing them.
module RenderBudget
  DEFAULT_SECONDS = 60

  class Exceeded < RuntimeError; end

  @mutex = Mutex.new
  @used = 0.0
  @limit = nil
  @example = nil
  @exceeded = nil
  @report = ENV['MB_SOUND_RENDER_BUDGET'] == 'report'
  @over = []

  class << self
    attr_reader :used, :over

    def report? = @report

    # Starts counting for +example+ (an RSpec example).
    def start(example)
      spec = example.metadata[:render_budget]
      seconds =
        case spec
        when nil then DEFAULT_SECONDS
        when Hash
          raise ArgumentError, "render_budget: needs a reason: (#{example.location})" if spec[:reason].to_s.strip.empty?
          spec.fetch(:seconds)
        else
          raise ArgumentError, "render_budget: takes { seconds:, reason: } (#{example.location}, got #{spec.inspect})"
        end
      @mutex.synchronize do
        @used = 0.0
        @limit = seconds
        @example = example.location
        @exceeded = nil
      end
    end

    # Stops counting; returns the Exceeded error if the example went over.
    def finish
      @mutex.synchronize do
        @limit = nil
        @example = nil
        e = @exceeded
        @exceeded = nil
        e
      end
    end

    # Counts +frames+ at +rate+ written to an unpaced output; raises past the
    # budget.
    def count(frames, rate)
      error = @mutex.synchronize do
        next nil if @limit.nil?

        @used += frames / rate
        next nil if @used <= @limit || @exceeded

        @exceeded = Exceeded.new(
          "#{@example} rendered over #{@limit} s of audio to unpaced NullOutputs (sleep: false/:virtual).  " \
          'A realtime Session on an unpaced output renders as fast as it can while the example waits: use ' \
          'Session.new(realtime: false) with #process_buffer, or NullOutput sleep: :virtual (its waiter consumes the audio; ' \
          'see spec/support/render_budget.rb).  If the example really renders this much, tag it ' \
          'render_budget: { seconds: N, reason: "..." }.'
        )
        @over << [@example, @limit]
        @exceeded
      end
      raise error if error && !@report
    end
  end

  # Prepended to MB::Sound::NullOutput.
  module Counting
    def write(data)
      RenderBudget.count(data[0].length, sample_rate) unless @sleep == true
      super
    end
  end
end

MB::Sound::NullOutput.prepend(RenderBudget::Counting)

RSpec.configure do |config|
  config.before(:each) do |example|
    RenderBudget.start(example)
  end

  # Fails the example even if the raise happened (and was rescued) on a
  # render thread.
  config.after(:each) do
    e = RenderBudget.finish
    raise e if e && !RenderBudget.report?
  end

  config.after(:suite) do
    next unless RenderBudget.report? && !RenderBudget.over.empty?

    puts "\nExamples over their render budget (MB_SOUND_RENDER_BUDGET=report):"
    RenderBudget.over.uniq.each { |loc, limit| puts "  #{loc} (budget #{limit} s)" }
  end
end
