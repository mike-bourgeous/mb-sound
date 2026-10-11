
module MB
  module Sound
    module Plot
      # Terminal capabilities: size, color depth, and inline image
      # protocols, from the environment (never by querying the terminal,
      # so output stays deterministic and nothing waits for a reply).
      #
      # Environment overrides:
      # - PLOT_WIDTH / PLOT_HEIGHT: text plot size in columns and lines
      # - PLOT_COLOR: truecolor, 256, 16, or none (also NO_COLOR)
      # - PLOT_LOOK: the default text look (scope, blocks, mosaic, quad, spark, ascii)
      # - PLOT_THEME: dark or light (terminal background)
      # - PLOT_IMAGES: sixel, kitty, iterm, or 1 (detected) to show plots as
      #   inline images by default; 0 never
      module Terminal
        module_function

        # Text plot width in columns.
        def width
          env_int('PLOT_WIDTH') || MB::U.width
        end

        # Terminal height in lines.
        def height
          env_int('PLOT_HEIGHT') || MB::U.height
        end

        # The default color mode: :truecolor, :ansi256, :ansi16, or :none.
        def color_mode(env = ENV)
          case env['PLOT_COLOR']&.downcase
          when 'truecolor', '24bit', '24' then return :truecolor
          when '256', 'ansi256' then return :ansi256
          when '16', 'ansi16', '8' then return :ansi16
          when 'none', 'no', '0', 'off' then return :none
          end
          return :none if env.key?('NO_COLOR') || env['TERM'] == 'dumb'

          return :truecolor if %w[truecolor 24bit].include?(env['COLORTERM']&.downcase)
          return :truecolor if %w[iTerm.app WezTerm vscode].include?(env['TERM_PROGRAM'])
          return :truecolor if env['KONSOLE_VERSION'] || env['KITTY_WINDOW_ID'] || env['TERM'].to_s.include?('kitty')
          return :ansi256 if env['TERM'].to_s.include?('256')

          :ansi16
        end

        # The default text look (a Symbol).
        def look(env = ENV)
          env['PLOT_LOOK']&.to_sym || :scope
        end

        # The default terminal theme (:dark or :light).
        def theme(env = ENV)
          return env['PLOT_THEME'].to_sym if %w[dark light].include?(env['PLOT_THEME'])

          # COLORFGBG is "fg;bg" in rxvt, Konsole, iTerm2; bg 7 or 15 is light
          bg = env['COLORFGBG']&.split(';')&.last.to_i
          [7, 15].include?(bg) ? :light : :dark
        end

        # The inline image protocol the terminal supports (:kitty, :iterm,
        # :sixel), or nil.  Inside tmux the escape is wrapped for
        # passthrough (tmux needs `set -g allow-passthrough on`).
        def image_protocol(env = ENV)
          forced = env['PLOT_IMAGES']&.downcase
          return forced.to_sym if %w[sixel kitty iterm].include?(forced)

          prog = env['TERM_PROGRAM'] || env['LC_TERMINAL']
          return :iterm if prog == 'iTerm.app' || env['LC_TERMINAL'] == 'iTerm2'
          return :iterm if prog == 'WezTerm'
          return :kitty if env['KITTY_WINDOW_ID'] || env['TERM'].to_s.include?('kitty') || prog == 'ghostty'
          return :sixel if env['KONSOLE_VERSION'] && env['KONSOLE_VERSION'].to_i >= 220400

          nil
        end

        # True if PLOT_IMAGES asks for inline images by default and the
        # terminal has a protocol.
        def images_by_default?(env = ENV)
          v = env['PLOT_IMAGES']&.downcase
          return false if v.nil? || v == '0' || v == 'no'

          !image_protocol(env).nil?
        end

        # Image size in pixels for a full-width inline plot (PLOT_PIXELS
        # "WxH", else 10x20-pixel cells).
        def pixel_size(env = ENV)
          if env['PLOT_PIXELS'] =~ /\A(\d+)x(\d+)\z/
            return [$1.to_i, $2.to_i]
          end

          [(width * 10).clamp(320, 2400), ((height * 0.6) * 20).round.clamp(200, 1600)]
        end

        # The escape sequence that shows +image+ (a Plot::Image::Canvas)
        # inline with +protocol+, sized to +columns+ terminal columns.
        def image_escape(image, protocol, columns: nil, env: ENV)
          png = image.to_png unless protocol == :sixel
          seq =
            case protocol
            when :iterm
              "\e]1337;File=inline=1;size=#{png.bytesize};preserveAspectRatio=1#{";width=#{columns}" if columns}:#{[png].pack("m0")}\a"
            when :kitty
              data = [png].pack("m0")
              chunks = data.scan(/.{1,4096}/m)
              chunks.each_with_index.map { |c, i|
                more = i < chunks.length - 1 ? 1 : 0
                head = i == 0 ? "a=T,f=100,q=2#{",c=#{columns}" if columns}," : ''
                "\e_G#{head}m=#{more};#{c}\e\\"
              }.join
            when :sixel
              Image::Sixel.encode(image.rgb)
            else
              raise ArgumentError, "Unknown image protocol #{protocol.inspect} (:iterm, :kitty, :sixel)"
            end

          env['TMUX'] ? tmux_wrap(seq) : seq
        end

        # Wraps an escape sequence for tmux passthrough.
        def tmux_wrap(seq)
          "\ePtmux;#{seq.gsub("\e", "\e\e")}\e\\"
        end

        def env_int(name)
          v = ENV[name]&.to_i
          v && v > 0 ? v : nil
        end
      end
    end
  end
end
