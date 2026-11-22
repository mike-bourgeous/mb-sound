module MB
  module Sound
    module UI
      # Threads that hand the GVL to the live render thread as soon as it
      # wants it (FastUI::GVLYield; ui-wave-perf-1 round 3,
      # design/notes/sound_design_ui.md "The workers yield").  Ruby
      # otherwise switches threads only at its timer
      # (RUBY_THREAD_TIMESLICE, 10 ms in the shebang) or when the running
      # thread blocks, and the sound-design screen's preview workers run
      # 10-30 ms of Ruby at a time (a voice copy's build, its first blocks,
      # a chart): the render thread, woken for its next buffer, waited until
      # then.  A yielder gives the GVL up at its next interrupt check (a
      # method return or loop branch) once the render thread is ready to
      # run; thread switches change nothing a thread computes.
      #
      # The preview workers (PatchRender::Worker, ChartWorker) join when
      # their thread starts and leave when it ends; renders name the render
      # thread (.follow, from PatchRender::Source#thread).  Another thread
      # joins with one call, e.g. a screen's painter:
      #
      #     MB::Sound::UI::Yielding.join(painter_thread, render: session.render_thread)
      #     # ... and when the painter ends:
      #     MB::Sound::UI::Yielding.leave(painter_thread)
      #
      # Both are idempotent; a thread that ends is dropped from the table by
      # the extension itself.  Nothing runs (no hook, no kicker thread)
      # until a render thread and a yielder are both set; with .on false (or
      # MB_SOUND_YIELD=0), or without the extension, .join does nothing and
      # returns false (saying why once).
      module Yielding
        @on = ENV['MB_SOUND_YIELD'] != '0' && ENV['MB_SOUND_PREVIEW_YIELD'] != '0'
        @painter = ENV['MB_SOUND_PAINTER_YIELD'] != '0'
        @input = ENV['MB_SOUND_INPUT_YIELD'] != '0'
        @closing = nil
        @said = false

        class << self
          # True: .join registers threads (new joins only).
          attr_accessor :on

          # True (the default; MB_SOUND_PAINTER_YIELD=0 turns it off): the
          # screens' painter threads yield (FrameRate#yield_to_render;
          # ui-perf-2).  Read when a painter first follows a render thread.
          attr_accessor :painter

          # True (the default; MB_SOUND_INPUT_YIELD=0 turns it off): the
          # tiled screen's input thread yields too, joined by its painter
          # (a knob key's handler held the GVL up to 19 ms on the Mac i9
          # during a sweep, as often as the painter; ui-perf-2).
          attr_accessor :input

          # True when the extension's GVLYield is there.
          def available? = defined?(FastUI::GVLYield) ? true : false

          # Makes +thread+ (default: the calling thread) give the GVL to the
          # render thread whenever that waits for it, and with +render+ names
          # that thread (.follow).  Returns true if +thread+ yields.
          def join(thread = Thread.current, render: nil)
            return false unless @on && usable?
            # (the hook and kicker thread stop at exit, before Ruby's
            # threads are torn down)
            @closing ||= ExitClose.register(self)
            ok = FastUI::GVLYield.add(thread)
            follow(render) if render
            ok
          end

          # +thread+ stops yielding; the render thread is let go when no
          # thread yields any more.
          def leave(thread = Thread.current)
            return nil unless available?
            FastUI::GVLYield.remove(thread)
            FastUI::GVLYield.priority = nil if FastUI::GVLYield.yielders.empty? && !FastUI::GVLYield.priority.nil?
            nil
          end

          # The thread yielders give the GVL to (the live session's render
          # thread; nil or a dead thread: unchanged).
          def follow(thread)
            return nil unless thread && @on && available? && thread.alive?
            FastUI::GVLYield.priority = thread unless FastUI::GVLYield.priority.equal?(thread)
            nil
          end

          # Yielders stop following +thread+ if it is the followed render
          # thread (Session#close, after its render thread ended).  The
          # hook drops yielders that end, but the hook and kicker stopped
          # only on a later join or leave: a screen stopped while the
          # Session's scheduler still yielded left the closed Session's dead
          # render thread followed, and the kicker running with no yielder
          # (fast_ui_spec's GVLYield example after live_threads_spec, merge
          # train 2026-11-22).
          def unfollow(thread)
            return nil unless thread && available? && FastUI::GVLYield.priority.equal?(thread)
            FastUI::GVLYield.priority = nil
            nil
          end

          # True while the hook runs (a render thread and a yielder set).
          def active? = available? && FastUI::GVLYield.active?

          # { kicks:, retries:, yields:, wakeups: } since the process started
          # (FastUI::GVLYield.stats), or {} without the extension.
          def stats = available? ? FastUI::GVLYield.stats : {}

          # Stops all yielding (ExitClose at exit).
          def close
            return nil unless available?
            FastUI::GVLYield.yielders.each { |t| FastUI::GVLYield.remove(t) }
            FastUI::GVLYield.priority = nil
            nil
          end

          private

          def usable?
            return true if available?
            unless @said
              @said = true
              warn 'MB::Sound::UI::Yielding: the fast_ui extension has no GVLYield (rebuild it: bundle exec rake compile); threads keep Ruby\'s timeslice'
            end
            false
          end
        end
      end
    end
  end
end
