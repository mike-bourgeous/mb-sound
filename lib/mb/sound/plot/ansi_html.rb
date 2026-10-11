module MB
  module Sound
    module Plot
      # Converts text with ANSI SGR color codes (as Plot::Text writes them:
      # truecolor, 256-color, 16-color, bold, reverse) to HTML spans, for
      # viewing terminal plots in a browser.
      module AnsiHtml
        module_function

        # HTML (a <pre> block's contents) for +text+ with ANSI codes.  +fg+
        # and +bg+ are the default colors (used for reversed cells).
        def convert(text, fg: '#d8d8d2', bg: '#141413')
          out = +''
          state = { fg: nil, bg: nil, bold: false, reverse: false }
          open = false
          text.scan(/\e\[([\d;]*)m|([^\e]+)/m) do |codes, chunk|
            if codes
              apply(state, codes)
              next
            end

            out << '</span>' if open
            style = css(state, fg, bg)
            if style.empty?
              open = false
            else
              out << %(<span style="#{style}">)
              open = true
            end
            out << escape(chunk)
          end
          out << '</span>' if open
          out
        end

        # A minimal HTML page showing +text+ (with ANSI codes) in a dark
        # terminal-like block.
        def page(text, title: 'plot')
          <<~HTML
            <!doctype html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>#{escape(title)}</title>
            <style>body{margin:0;background:#141413;color:#d8d8d2}pre{margin:16px;font:13px/1.15 ui-monospace,Menlo,'DejaVu Sans Mono',Consolas,monospace}</style>
            </head><body><pre>#{convert(text)}</pre></body></html>
          HTML
        end

        def escape(s)
          s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end

        def apply(state, codes)
          parts = codes.split(';').map(&:to_i)
          parts = [0] if parts.empty?
          i = 0
          while i < parts.length
            c = parts[i]
            case c
            when 0
              state.merge!(fg: nil, bg: nil, bold: false, reverse: false)
            when 1 then state[:bold] = true
            when 22 then state[:bold] = false
            when 7 then state[:reverse] = true
            when 27 then state[:reverse] = false
            when 30..37 then state[:fg] = basic(c - 30)
            when 90..97 then state[:fg] = basic(c - 90 + 8)
            when 40..47 then state[:bg] = basic(c - 40)
            when 100..107 then state[:bg] = basic(c - 100 + 8)
            when 39 then state[:fg] = nil
            when 49 then state[:bg] = nil
            when 38, 48
              key = c == 38 ? :fg : :bg
              if parts[i + 1] == 2
                state[key] = format('#%02x%02x%02x', parts[i + 2], parts[i + 3], parts[i + 4])
                i += 4
              elsif parts[i + 1] == 5
                state[key] = xterm(parts[i + 2])
                i += 2
              end
            end
            i += 1
          end
        end

        def css(state, dfg, dbg)
          fg = state[:fg]
          bg = state[:bg]
          if state[:reverse]
            fg, bg = (bg || dbg), (fg || dfg)
          end
          s = []
          s << "color:#{fg}" if fg
          s << "background:#{bg}" if bg
          s << 'font-weight:bold' if state[:bold]
          s.join(';')
        end

        def basic(k)
          Color.hex(Text::ANSI::BASIC[k])
        end

        def xterm(n)
          return basic(n) if n < 16

          if n >= 232
            v = 8 + (n - 232) * 10
            return Color.hex([v, v, v])
          end

          n -= 16
          levels = [0, 95, 135, 175, 215, 255]
          Color.hex([levels[n / 36], levels[(n / 6) % 6], levels[n % 6]])
        end
      end
    end
  end
end
