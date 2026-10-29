module MB
  module Sound
    module Generative
      # Computes generator cycles ahead of playback on a realtime Session's
      # scheduler thread (Session::Scheduler#background), so the render
      # thread only reads cached cycles: when a cycle is read, the next one
      # is queued.  Without a realtime session (renders, specs) nothing is
      # queued and cycles are computed where they are read, which gives the
      # same events (generators are pure functions of the cycle).
      module Ahead
        @mutex = Mutex.new
        @runners = []
        @pending = {}
        @computed = 0

        class << self
          # Cycles computed in the background so far (for specs and stats).
          attr_reader :computed

          # Adds a runner (anything with #background(&block) returning true
          # when it queued the block); the newest one is used.
          def attach(runner)
            @mutex.synchronize { @runners.delete(runner); @runners << runner }
          end

          # Removes a runner (a closing Session's scheduler).
          def detach(runner)
            @mutex.synchronize { @runners.delete(runner) }
          end

          # The runner in use, or nil.
          def runner
            @mutex.synchronize { @runners.last }
          end

          # Queues +cycle+ of +generator+ unless it's cached or queued
          # (+data+ goes to Generator#compute_ahead: a steered generator's
          # clip length and origin).
          def request(generator, cycle, data = nil)
            r = nil
            key = [generator, cycle]
            @mutex.synchronize {
              r = @runners.last
              return false if r.nil? || @pending.key?(key)
              @pending[key] = true
            }
            if data.nil? && generator.cached?(cycle)
              @mutex.synchronize { @pending.delete(key) }
              return false
            end

            queued = r.background {
              begin
                if data
                  generator.compute_ahead(cycle, data)
                elsif !generator.cached?(cycle)
                  generator.compute(cycle)
                end
                @mutex.synchronize { @computed += 1 }
              rescue StandardError => e
                warn "Generator #{generator} failed computing cycle #{cycle} ahead: #{e.class}: #{e.message}"
              ensure
                @mutex.synchronize { @pending.delete(key) }
              end
            }
            @mutex.synchronize { @pending.delete(key) } unless queued
            queued
          end
        end
      end
    end
  end
end
