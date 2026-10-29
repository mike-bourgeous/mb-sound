module MB
  module Sound
    module Plot
      module Panels
        # The envelope preview (envelope-view-1; design in
        # design/notes/sound_design_ui.md, The envelope preview): a copy of
        # the envelope (an Envelope made from Envelope#preview_data, never
        # the live one) rendered at a low rate through one note: the
        # attack and decay segments at their times, the sustain held for a
        # fixed share of the plot (SUSTAIN_SHARE), then the release.  Dashed
        # rules mark the breakpoints; the title names them in real units
        # (A 5ms D 200ms S -3.1dB R 300ms); the time axis says its span and
        # step ("1.24s 0.2s/div").  With a live note (+live+, see .draw) a
        # playhead shows where it is (held at the sustain point while the
        # key is down), and a second trace the levels it actually reaches
        # when its peak isn't 1 (velocity).
        module EnvelopeView
          # The share of the plot the sustain holds for (gated envelopes).
          SUSTAIN_SHARE = 0.35

          # Samples the copy renders over the whole plot (its rate is
          # chosen for this many, at most MAX_RATE).
          POINTS = 2048

          # The highest rate the copy renders at.
          MAX_RATE = 48000.0

          # Seconds a segment is drawn for when a node gives its time and
          # the node's value isn't known (an LFO; knobs show their value).
          UNKNOWN_TIME = 0.1

          # The level drawn when a node gives a segment's level.
          UNKNOWN_LEVEL = 0.5

          # Room after the release, as a share of the plot.
          TAIL = 0.04

          # Traces kept (by preview data).
          KEEP = 8

          # The rendered copy: +time+ and +level+ (DFloats, seconds and
          # levels at peak 1), +total+ (the plot's seconds), +starts+
          # (each segment's start in plot seconds), +release_start+,
          # +release_end+, +sustain_at+ (where the sustain starts: the
          # playhead's place while the key is held), +release_node+,
          # +breaks+ (rule positions), +label+ (the title's breakpoints),
          # +rate+ (the copy's sample rate).
          Trace = Data.define(:time, :level, :total, :starts, :release_start, :release_end, :sustain_at, :release_node, :breaks, :label, :rate)

          @cache = {}
          @lock = Mutex.new

          class << self
            # Draws envelope preview data +d+ (Envelope#preview_data) onto
            # +chart+, with +live+ (nil, or a Hash: +:stage+ (:segment or
            # :sustain), +:segment+, +:position+ (seconds into the segment),
            # +:elapsed+ (seconds since it was read, added while the
            # segment runs), +:peak+ (the note's peak level)) for a
            # playhead and the velocity trace.  Returns the chart.
            def draw(d, chart, live = nil)
              tr = trace(d)
              peak = live && live[:peak]
              scaled = peak && (peak - 1.0).abs > 0.005
              title = tr.label
              title += " pk #{level_db(peak)}" if scaled
              focus = live && live[:focus] && focus_of(d, tr, live[:focus])
              title = "▸#{live[:focus]} #{title}" if focus
              chart.title(title)
              chart.x Scale::Time.new(0.0..tr.total, divisions: 5)
              lo = [tr.level.min, 0.0].min
              hi = [tr.level.max, 1.0].max
              lo = [lo, (tr.level * peak).min].min if scaled
              hi = [hi, (tr.level * peak).max].max if scaled
              chart.y Scale::Linear.new(lo..hi, label: nil, nice: false)
              tr.breaks.each { |b| chart.rule(x: b, dash: [1, 2]) }
              chart.line tr.level, x: tr.time, label: 'envelope'
              chart.line tr.level * peak, x: tr.time, label: "velocity #{peak.round(2)}" if scaled
              t = live && playhead(tr, live)
              chart.rule(x: t, color: 3) if t
              # (the point the inspector picked: sound-design-2's editor)
              if focus
                axis, at = focus
                axis == :x ? chart.rule(x: at, color: 2) : chart.rule(y: at, color: 2)
              end
              chart
            end

            # Where the inspector's picked param +name+ (+:focus+ in
            # .draw's +live+) is on the plot: [:x, seconds] for a segment's
            # time or curve (its end), [:y, level] for a level (:sustain,
            # :t2_level), or nil for other params.
            def focus_of(d, tr, name)
              names = d[:names]
              rel = tr.release_node
              seg_end = ->(i) { tr.starts[i] + (d[:times][i] || UNKNOWN_TIME).to_f }
              level = ->(i) { (d[:levels][i] || UNKNOWN_LEVEL).to_f }
              n = name.to_s
              if (i = names.index(name.to_sym)) then [:x, seg_end.(i)]
              elsif n == 'sustain' && rel > 0 then [:y, level.(rel - 1)]
              elsif (m = n.match(/\A(.+)_level\z/)) && (i = names.index(m[1].to_sym)) then [:y, level.(i)]
              elsif (m = n.match(/\A(.+)_curve\z/)) && (i = names.index(m[1].to_sym)) then [:x, seg_end.(i)]
              end
            end

            # The rendered copy for preview data +d+ (kept for the last few
            # +d+s; see Trace).
            def trace(d)
              hit = @lock.synchronize { (t = @cache.delete(d)) && (@cache[d] = t) }
              return hit if hit
              tr = build(d)
              @lock.synchronize {
                @cache[d] = tr
                @cache.shift while @cache.length > KEEP
              }
              tr
            end

            # The playhead's time on the plot for +live+ (see .draw), or nil
            # when the note isn't sounding: the segment's start plus where
            # it is (and +:elapsed+), up to the sustain point before the
            # release and the release's end after it.
            def playhead(tr, live)
              case live[:stage]
              when :sustain
                tr.sustain_at
              when :segment
                k = live[:segment].to_i
                return nil unless k.between?(0, tr.starts.length - 1)
                t = tr.starts[k] + live[:position].to_f + live[:elapsed].to_f
                k < tr.release_node ? [t, tr.sustain_at].min : [t, tr.release_end].min
              end
            end

            private

            def build(d)
              names = d[:names]
              rel = d[:release_node]
              times = d[:times].map { |t| t.nil? ? UNKNOWN_TIME : [t.to_f, 0.0].max }
              levels = d[:levels].map { |l| l.nil? ? UNKNOWN_LEVEL : l.to_f }
              pre = times[0...rel].sum
              post = times[rel..].sum
              hold = d[:hold]
              release_start =
                if d[:gated] || !hold.is_a?(Numeric)
                  pre + (pre + post > 0 ? SUSTAIN_SHARE / (1 - SUSTAIN_SHARE) * (pre + post) : UNKNOWN_TIME)
                else
                  hold.to_f
                end
              release_end = release_start + post
              total = [release_end * (1 + TAIL), 1e-3].max
              rate = (POINTS / total).clamp(1.0, MAX_RATE)

              segs = names.each_index.map { |i| [levels[i], times[i], d[:curves][i], d[:shapes][i]] }
              n = (total * rate).ceil
              on = (release_start * rate).round
              env = Envelope.new(segments: segs, release_at: rel, loop: d[:loop_node], gate: Envelope::PreviewGate.new(on, rate),
                                 sensitivity: nil, hold_last: d[:hold_last], sample_rate: rate)
              level = Numo::DFloat.cast(env.sample(n))
              time = Numo::DFloat.new(n).seq / rate

              starts = []
              acc = 0.0
              times[0...rel].each { |t| starts << acc; acc += t }
              acc = release_start
              times[rel..].each { |t| starts << acc; acc += t }
              ends = starts.zip(times).map { |s, t| s + t }
              breaks = (ends[0...rel] + [release_start] + ends[rel..]).select { |b| b > 0 && b < total && b <= release_end + 1e-12 }
              breaks = breaks.uniq { |b| (b * rate).round }

              Trace.new(time: time, level: level, total: total, starts: starts.freeze, release_start: release_start,
                        release_end: release_end, sustain_at: [pre, release_start].min, release_node: rel,
                        breaks: breaks.freeze, label: label(d, times, rel), rate: rate)
            end

            # The breakpoints in real units: "A 5ms D 200ms S -3.1dB R
            # 300ms" (ADSR), or "t1 10ms→1 t2 250ms→0.5 | t3 300ms→0"
            # (multi-segment), "~" for times and levels from nodes.
            def label(d, times, rel)
              t = ->(i) { d[:times][i].nil? ? '~' : seconds(times[i]) }
              text =
                if d[:multi]
                  d[:names].each_index.map { |i|
                    lv = d[:levels][i].nil? ? '~' : MB::M.sigfigs(d[:levels][i], 2).to_s.sub(/\.0\z/, '')
                    "#{'| ' if i == rel}#{d[:names][i]} #{t.(i)}→#{lv}"
                  }.join(' ')
                else
                  s = d[:levels][rel - 1]
                  "A #{t.(0)} D #{t.(1)} S #{s.nil? ? '~' : level_db(s)} R #{t.(rel)}"
                end
              text += " loop #{d[:names][d[:loop_node]]}" if d[:loop_node]
              text += " ×2^(#{MB::M.sigfigs(d[:octaves], 3)} oct)" if d[:octaves]
              text
            end

            def seconds(s)
              return '0' if s == 0
              s < 1 ? "#{MB::M.sigfigs(s * 1000, 3).to_s.sub(/\.0\z/, '')}ms" : "#{MB::M.sigfigs(s, 3).to_s.sub(/\.0\z/, '')}s"
            end

            def level_db(l)
              return '-inf' if l.to_f <= 0
              "#{(20 * Math.log10(l.to_f)).round(1)}dB"
            end
          end
        end
      end
    end
  end
end
