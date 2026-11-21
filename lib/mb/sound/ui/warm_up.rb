module MB
  module Sound
    module UI
      # Made-up snapshots of a set playing (for warming up the painter and
      # for previews): a drop at 128 bpm with four tracks, two knobs,
      # moving meters, and a scope, at time +t+ seconds.
      module Demo
        module_function

        def snapshot(t, seq: (t * 30).round + 1)
          pos = Sequence::TempoMap.whole_notes_at(t.to_f, 128).rationalize(1/96r) + 16
          stamp = Session::Stamp.new(pos: pos)
          wobble = Math.sin(t * 7.1) * 2.5
          phase = Numo::SFloat.new(Feed::SCOPE_LENGTH).seq * (2 * Math::PI * 110 / 48000) + 2 * Math::PI * t
          scope = [0.6, 0.3].map { |a| (Numo::NMath.sin(phase) * a).freeze }.freeze
          Snapshot.fake(
            seq: seq, time: t, frame: (t * 48000).round, pos: pos, bar: stamp.bar, beat: stamp.beat, bpm: 128, playing: true,
            load: 0.2 + 0.05 * Math.sin(t), load_max: 0.4,
            parts: [
              PartLoad.new(name: :drums, kind: :player, state: :playing, load: 0.04),
              PartLoad.new(name: :bass, kind: :player, state: :playing, load: 0.11),
              PartLoad.new(name: :hook, kind: :player, state: :playing, load: 0.07),
              PartLoad.new(name: :verb, kind: :bus, state: :playing, load: 0.05),
              PartLoad.new(name: :master, kind: :master, state: :playing, load: 0.02),
            ].freeze,
            master: MasterLevels.new(peak: [-7.5 + wobble, -8.0 + wobble].freeze, rms: [-17.0 + wobble, -17.4 + wobble].freeze, true_peak: -6.8 + wobble, lufs_s: -13.9),
            scope: scope, underruns: 0,
            knobs: [KnobValue.new(name: :cut, value: 1200.0 + 800 * Math.sin(t), spec: GraphNode::Knob::Spec.new(name: :cut, default: 700, range: 200..6000, curve: :exp, unit: 'Hz'))].freeze,
            slow: Slow.new(
              tracks: %i[drums bass hook pad].map { |n| TrackInfo.new(name: n, q: '1', clip: "#{n}_a", armed: n == :pad) }.freeze,
              scenes: %i[intro drop break].freeze, scene: :drop,
              queued: [QueuedInfo.new(seq: 1, kind: :scene, subject: :break, lands: '25:1', pos: 24r)].freeze,
              recording: [].freeze, armed: [:pad].freeze,
              form: FormInfo.new(section: :drop, pass: 1, from: 16r, to: 24r, next: :break, next_at: '25:1', committed: true, looping: false, ended: false),
              knob_specs: {}.freeze
            )
          )
        end
      end

      # Buffer sizes of UI.warm_up's short sessions (one session each).
      RENDER_SESSIONS = [256, 800, 128, 512, 256, 800].freeze

      # Draws every built-in pane for +frames+ refreshes of Demo snapshots
      # into grids nobody sees (and runs a Poll on a silent Session), so
      # YJIT has compiled the painter before a band goes on screen (its
      # first frames otherwise hold the GVL for tens of milliseconds while
      # compiling).  Before that, the render thread's side of a screen
      # (snapshots, meters, the scope) in short sessions.  Once per
      # process; nil without YJIT.  Returns seconds.
      def self.warm_up(frames: 130)
        return nil if @warmed || !JIT.compiling?
        @warmed = true
        t0 = MB::U.clock_now

        # The render thread's side: snapshots with meters and a scope, in
        # RENDER_SESSIONS short sessions of different buffer sizes, with
        # the painter taking every other snapshot.  A session's, a
        # player's, and a feed's first buffers run code once each (their
        # setup, the meters' filters), which YJIT compiles at its fifth
        # call: with one session here, the next four songs a process played
        # compiled it in their first buffer on the render thread (ui-perf-2
        # step 2: a 26-41 ms buffer at bar 1 on the emulated i9, ~500
        # blocks, about half of them the feed's).
        session = nil
        RENDER_SESSIONS.each_with_index do |n, k|
          session&.close
          session = Session.new(output: NullOutput.new(channels: 2, sleep: false), realtime: false, transport: Sequence::Transport.new)
          session.knob(:warm_up, 0.5)
          feed = Feed.new
          feed.needs = %i[meters scope]
          session.ui_feed = feed
          session.add(110.hz.triangle.at(-20.db), name: :warm_up)
          session.add(165.hz.ramp.at(-24.db), name: :warm_up_2) if k.odd?
          (frames / 10).times do |i|
            session.process_buffer(n)
            feed.take if i.even?
          end
        end
        poll = Poll.new(session)
        warm_up_poll

        # Every pane (the deck has them all) drawn each refresh, then the
        # diffed path
        sink = File.open(File::NULL, 'w')
        t = 0.0
        band = Band.new(layout: layouts[:deck], io: sink, size: [40, 160], clock: -> { t }, source: -> { Demo.snapshot(t) })
        frames.times do |i|
          t = i / 30.0
          poll.call if i % 4 == 0
          band.invalidate if i < frames - 10
          band.refresh(t)
          Thread.pass
        end
        MB::U.clock_now - t0
      ensure
        session&.close
        sink&.close
      end

      # Polls (Poll#call: slow data, as the painter does 4 times a second)
      # a small set in a session of its own: tracks, a kit with a fill,
      # sequences with rests, ties, swing, and legato, scenes, and a knob.
      # A set's first poll writes each clip's Ruby (ClipInfo#ruby), and
      # cold that compiled the recipe writer and the poll on the painter:
      # Last Stop's first poll took 111 ms natively, 94 ms of it YJIT
      # compiling 3422 blocks in stretches no handover can interrupt; after
      # this, 18 ms (13 ms, 592 blocks; ui-perf-2 step 3).  Costs ~135 ms
      # natively once per process.
      def self.warm_up_poll
        ws = Session.new(output: NullOutput.new(channels: 2, sleep: false), realtime: false, transport: Sequence::Transport.new)
        Session.with_context(session: ws) do
          MB::Sound.instance_eval do
            knob :wu_cut, 900, range: 100..8000
            kit = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.', clap: '....X.......X...')
              .fill(:turn, clap: grid(16, '....X...x.x.xXXX', value: 39)).loop(align: :launch)
            n = ->(m) { Note.new(m) } # (A1 = 33; the note constants are the console's)
            a = seq(R, n[33], R, n[33], R, n[33], R, n[33]).n8.loop(align: :launch)
            b = seq(R, R, !n[33], n[33], R, n[36], R, n[31]).n16.swing(0.56).loop(align: :launch)
            c = seq(n[76], Tie, Tie, Tie).n1.loop(align: :launch).named(:wu_tension)
            d = seq(n[45], n[45], n[45], n[43]).n1.legato(0.98).loop(align: :launch)
            e = seq(n[81], n[84], n[88], n[83]).n16.loop(align: :launch)
            track(:wu_drums) { |k| k.tone.sine.at(0.1) }
            track(:wu_bass) { |clip| clip.tone.saw.at(0.1).filter(:lowpass, cutoff: knob(:wu_cut)) * clip.env(0.01, 0.1, 0.5, 0.1) }
            track(:wu_lead) { |clip| clip.tone.triangle.at(0.1) * clip.env(0.01, 0.1, 0.5, 0.1) }
            scene :wu_a, wu_drums: kit, wu_bass: a, wu_lead: c
            scene :wu_b, wu_drums: kit, wu_bass: b, wu_lead: d
            scene :wu_c, wu_bass: a, wu_lead: e, wu_cut: 2000
          end
        end
        # (a new Poll each time: each caches its clips' Ruby)
        6.times { Poll.new(ws).call(%i[meters scope]) }
      ensure
        ws&.close
      end
      private_class_method :warm_up_poll

      # Lines .warm_up_console types: the kinds of console lines a set
      # takes (numbers, symbols, strings, assignments, method calls).
      CONSOLE_LINES = ['5', '13', ':a', '"text"', 'x = [1, 2, 3]', 'x.length', 'nil', '1 + 2', '135', '0.25'].freeze

      # Types CONSOLE_LINES (+rounds+ times) into a Pry of its own on a
      # private pty (MB::Term::Input::ReplHost, reading through Reline as
      # the console does, with the console's Pry hooks), so YJIT has
      # compiled the console's line editing, evaluation, and printing
      # before anything plays (tuner-fixes-1: the maintainer's "Entering
      # numbers in Pry caused the music to lose its step ... on the first
      # couple": measured with bin/ui_demo.rb --tiles --type, the first
      # five console lines held the GVL in 10 ms slices while YJIT compiled
      # them, 25 render-thread waits over 1 ms; YJIT's call threshold is 5,
      # JIT::CALL_THRESHOLD).  The lines go to no take (Take.discarding),
      # no history (Pry's and Reline's are put back), and Pry's line counter
      # is put back.  Once per process; nil without YJIT.  Returns seconds.
      def self.warm_up_console(rounds: 2, lines: CONSOLE_LINES, timeout: 5.0)
        return nil if @console_warmed || !JIT.compiling?
        @console_warmed = true
        require 'pry'
        t0 = MB::U.clock_now
        saved = { history: Pry.config.history, save: Pry.config.history_save, line: Pry.current_line, buffer: Pry.line_buffer.dup,
                  reline: (defined?(Reline::HISTORY) ? Reline::HISTORY.length : nil) }
        Pry.config.history_save = false
        Pry.config.history = Pry::History.new(file_path: File::NULL)
        host = nil
        Take.discarding do
          host = MB::Term::Input::ReplHost.new(rows: 4 * lines.length * rounds + 10, cols: 120, mode: :thread, target: Take.console_binding,
                                               pry: { prompt: Pry::Prompt.new(:warm_up, 'warm-up', [proc { 'w> ' }, proc { 'w* ' }]), pager: false })
          host.start
          results = 0
          (lines * rounds).each do |line|
            host.write("#{line}\r")
            results += 1
            deadline = MB::U.clock_now + timeout
            sleep 0.001 until host.synchronize { host.vt.text.scan('=> ').length } >= results || MB::U.clock_now > deadline
          end
        end
        MB::U.clock_now - t0
      ensure
        host&.stop
        if saved
          Pry.config.history = saved[:history]
          Pry.config.history_save = saved[:save]
          Pry.current_line = saved[:line]
          Pry.line_buffer = saved[:buffer]
          Reline::HISTORY.pop while saved[:reline] && Reline::HISTORY.length > saved[:reline]
        end
      end
    end
  end
end
