module MB
  module Sound
    module UI
      # Builds and draws a pane's chart off the painter (ui-wave-perf-1
      # round 3; design/notes/sound_design_ui.md, "The workers yield"): the
      # sound-design screen's preview pane rebuilds its chart when a knob
      # turns (a filter's response, a shaper's curve, an oscillator's
      # rendered cycle), and building and drawing it took the painter 3-7 ms
      # (up to 28) holding the GVL.  Here a low-priority thread (a
      # UI::Yielding yielder: it gives the GVL to the render thread
      # whenever that wants it) builds the newest chart asked for and draws
      # it into its own cells; the painter only copies cells.
      #
      # #draw returns the cells of the newest chart drawn for the pane's size
      # and look, while a newer one is built (so a turned knob shows a frame
      # or a few later, and the same picture once drawn).  With nothing drawn
      # yet at that size (the first draw, a resize), or with
      # PatchRender.inline (specs, captures), the chart is drawn on the
      # calling thread at once, as before.
      class ChartWorker
        # Seconds without work before the thread ends.
        IDLE = 10.0

        # One request: +key+ (equal for the same chart), +w+, +h+, +look+,
        # +cells+ (the grid's class), +build+ (a callable returning the chart
        # or nil), +source+ (a PatchRender::Source whose render thread the
        # worker yields to, or nil).
        Job = Struct.new(:key, :w, :h, :look, :cells, :build, :source)

        def initialize
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @job = nil # (the newest request not yet started)
          @running = nil # (the request being built)
          @done = nil # [key, w, h, look, cells class, cells or nil]
          @thread = nil
          @closed = false
          @lives = {}
        end

        # The cells of the chart +key+ (built by the block when needed) at
        # +w+ x +h+ cells in +look+ for a grid of +cells+ class, or of the
        # newest one drawn at that size while +key+'s is built; nil when the
        # chart is nil.  Never raises from the block on the worker (the error
        # is warned and drawn as nothing).  +source+ (a PatchRender::Source)
        # names the render thread to yield to.
        def draw(key, w, h, look, cells, source = nil, &build)
          d = @mutex.synchronize { @done }
          same_size = d && d[1] == w && d[2] == h && d[3].equal?(look) && d[4].equal?(cells)
          return d[5] if same_size && d[0] == key
          if !same_size || PatchRender.inline || @closed
            out = ChartWorker.render(@lives, w, h, look, cells, build.call)
            @mutex.synchronize { @done = [key, w, h, look, cells, out].freeze }
            return out
          end
          @mutex.synchronize do
            unless (@running && @running.key == key && same_job?(@running, w, h, look, cells)) || (@job && @job.key == key && same_job?(@job, w, h, look, cells))
              @job = Job.new(key, w, h, look, cells, build, source)
              start unless @thread&.alive?
              @cond.signal
            end
          end
          d[5]
        end

        # True while a newer chart than the one drawn waits or is built.
        def pending? = @mutex.synchronize { !@job.nil? || !@running.nil? }

        # The worker thread, or nil (specs).
        def thread = @mutex.synchronize { @thread }

        # Stops the thread.
        def close
          t = @mutex.synchronize {
            @closed = true
            @job = nil
            @cond.signal
            @thread
          }
          t&.join
          nil
        end

        # Draws +chart+ (nil: nothing) into new +cells+ (a class) of +w+ x
        # +h+ in +look+ through a Plot::Live kept in +lives+ per size and
        # look; nil for no chart.
        def self.render(lives, w, h, look, cells, chart)
          return nil unless chart
          key = [w, h, look, cells]
          live = (lives[key] ||= Plot::Live.new(width: w, height: h, look: look, cells: cells))
          lives.shift while lives.length > 4
          out = cells.new(w, h)
          live.draw(chart, out, x: 0, y: 0)
          out
        end

        private

        def same_job?(j, w, h, look, cells) = j.w == w && j.h == h && j.look.equal?(look) && j.cells.equal?(cells)

        def start
          @thread = Thread.new { run }
          @thread.name = 'mb-sound chart render'
          @thread.priority = -3
          @thread.report_on_exception = false
        end

        def run
          UI::Yielding.join
          loop do
            job = @mutex.synchronize {
              deadline = MB::U.clock_now + IDLE
              while @job.nil? && !@closed
                left = deadline - MB::U.clock_now
                if left <= 0
                  @thread = nil
                  return
                end
                @cond.wait(@mutex, left)
              end
              if @closed
                @thread = nil
                return
              end
              @running = @job
              @job = nil
              @running
            }
            UI::Yielding.follow(job.source&.thread&.call)
            out = begin
              ChartWorker.render(@lives, job.w, job.h, job.look, job.cells, job.build.call)
            rescue StandardError => e
              warn "chart render: #{e.class}: #{e.message}"
              nil
            end
            @mutex.synchronize {
              @done = [job.key, job.w, job.h, job.look, job.cells, out].freeze
              @running = nil
            }
          end
        ensure
          UI::Yielding.leave
        end
      end
    end
  end
end
