module MB
  module Sound
    module Help
      # `now`: what is going on right now (players, knobs,
      # scenes, the flow, queued changes, recent changes) and the commands
      # that apply to it.  Reads only public Session state.
      class Now
        include Page
        include Text

        def initialize(session = Session.current)
          @s = session
        end

        def to_s
          w = width
          out = []
          stamp = @s.clock
          flow = (MB::Sound.flow rescue nil)
          head = "#{c(:title, 'now')} #{c(:key, stamp.to_s.sub(/^#<Stamp (\S+).*/, 'bar \1'))}  #{c(:dim, "#{fmt(MB::Sound.bpm)} bpm")}"
          head << "  #{c(:dim, 'paused')}" if @s.players.empty?
          out << head
          out << "  #{c(:head, 'flow')} #{flow.inspect.lines.first.chomp.sub(/\A#<Form::Playback /, '').chomp('>')}" if flow

          players = @s.players
          strip = @s.strip_info
          tracks = @s.arrangement.track_info
          unless players.empty?
            out << c(:head, 'players')
            players.each do |name, desc|
              flags = []
              flags << c(:warn, 'muted') if strip[:muted].include?(name)
              flags << c(:ok, 'solo') if strip[:soloed].include?(name)
              kind = tracks[name] ? "track #{tracks[name]}" : short(desc)
              out << "  #{pad(c(:name, name.inspect), 14)} #{kind[0, w - 30]} #{flags.join(' ')}"
            end
          end

          knobs = @s.knobs
          unless knobs.empty?
            out << c(:head, 'knobs')
            info = @s.knob_info
            knobs.each do |name, k|
              spec = k.spec
              target = info[name].to_s[/->\s*(\S+)/, 1]
              pos = spec.position(k.value).to_f.clamp(0, 1)
              out << "  #{pad(c(:name, name.inspect), 14)} #{meter(pos, 20)} #{fmt(k.value)}#{spec.unit ? " #{spec.unit}" : ''}#{target ? c(:key, " → #{target}") : ''} #{c(:dim, "#{fmt(spec.range.begin)}..#{fmt(spec.range.end)}#{spec.cc ? " cc#{spec.cc}" : ''}")}"
            end
          end

          scenes = @s.arrangement.scene_info
          unless scenes.empty?
            current = @s.arrangement.current_scene rescue nil
            out << "#{c(:head, 'scenes')} " + scenes.keys.map { |n| n == current ? c(:key, "▶#{n}") : n.to_s }.join('  ')
          end

          queued = @s.journal.changes.select { |e| e.status == :queued }
          unless queued.empty?
            out << c(:head, 'queued')
            queued.last(6).each { |e| out << "  #{e}" }
          end

          recent = @s.journal.changes.reject { |e| e.status == :queued }.last(4)
          unless recent.empty?
            out << c(:head, 'landed')
            recent.each { |e| out << "  #{c(:dim, e.to_s)}" }
          end

          out << ''
          out << c(:head, 'you can')
          suggestions(players, knobs, scenes, queued, flow).each { |s| out << "  #{s}" }
          out.join("\n")
        end

        private

        # Commands that fit the current state, filled in with real names.
        def suggestions(players, knobs, scenes, queued, flow)
          s = []
          if players.empty?
            s << "#{code('bg :x, 110.hz.saw.at(-20.db).lp4(800)')}  #{c(:dim, 'start something')}"
            s << "#{code('lesson')}  #{c(:dim, 'or a guided tour')}"
          end
          last = players.keys.last
          s << "#{code("stop #{last.inspect}")} / #{code("mute #{last.inspect}, on: :bar")}" if last
          if (k = knobs.keys.first)
            s << "#{code("turn #{k.inspect}, #{fmt(knobs[k].spec.range.end)}, over: 2.bars")}  #{code('snap :here')}"
          end
          unless scenes.empty?
            # The scene after the current one (wrapping), else the first
            names = scenes.keys
            cur = names.index(@s.arrangement.current_scene) rescue nil
            nxt = cur ? names[(cur + 1) % names.length] : names.first
            nxt = nil if nxt == names[cur.to_i] && cur
            s << "#{code("go #{nxt.inspect}")}  #{c(:dim, "lands at the track's q:")}" if nxt
          end
          s << "#{code('loop!')} #{code('onward')} #{code('finish')}  #{c(:dim, 'the form')}" if flow
          s << "#{code('undo')}  #{c(:dim, 'cancels queued changes; else at the next bar')}" if queued.any? || @s.undo_steps.any?
          s << "#{code('take.save')}  #{c(:dim, 'keep this')}" unless players.empty?
          if UI.band&.active?
            s << "#{code('ui :deck')} / #{code('ui off')}  #{c(:dim, 'the dashboard band')}"
          elsif !players.empty?
            s << "#{code('ui')}  #{c(:dim, 'a live dashboard band above the prompt')}"
          end
          s
        end

        def meter(pos, n)
          eighths = (pos * n * 8).round
          full, part = eighths.divmod(8)
          bar = '█' * full + (part > 0 ? [' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉'][part] : '')
          c(:bar, '▕' + pad(bar, n) + '▏')
        end

        def short(desc) = desc.to_s.sub(/ -- .*/, '').sub(%r{/id=\d+}, '')

        def fmt(v)
          v = v.to_f
          v.abs >= 100 || v == v.round ? v.round.to_s : format('%.3g', v)
        end
      end
    end
  end
end
