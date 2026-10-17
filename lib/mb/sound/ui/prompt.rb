require 'ripper'

module MB
  module Sound
    module UI
      # The console's prompts (bin/sound.rb): the main prompt with Pry's
      # line counter and the state only commands change (recording and
      # armed tracks, the form's section or the scene; never the playback
      # position or load, which a prompt drawn once can't keep current:
      # the band, the tiles' status line, and `now` show those), and a dim
      # continuation prompt for lines inside unclosed constructs, aligned
      # to the code and naming what is open (`{ do …`).
      #
      #     sound.rb [3] MB::Sound(0) > [1, 2].each do |x|
      #                          do … >   puts x
      module Prompt
        # Keywords that open a construct closed by `end`.
        BLOCK_KEYWORDS = %w[do begin def class module case for].freeze

        # Keywords that open a construct at the start of a statement (and
        # are modifiers after an expression).
        STATEMENT_KEYWORDS = %w[if unless while until].freeze

        # Token types after which an if/unless/while/until starts a
        # statement (not a modifier).
        STATEMENT_START = %i[on_nl on_ignored_nl on_semicolon on_lparen on_lbracket on_lbrace on_comma on_op on_tlambeg on_embexpr_beg].freeze

        class << self
          # The last main prompt (continuation prompts align to it).
          attr_reader :last

          # The main prompt for Pry (+obj+ the context, +nest+ the nesting
          # level, +pry+ the Pry instance), with \1 and \2 around color
          # codes for Reline's width.
          def main(obj, nest, pry)
            n = pry.respond_to?(:input_ring) ? pry.input_ring.count : nil
            status = UI.prompt_status
            @last = "\1\e[36m\2#{File.basename($0)}\1\e[0m\2 #{n ? "\1\e[2m\2[#{n}]\1\e[0m\2 " : ''}" \
                    "#{status ? "#{status} " : ''}\1\e[32m\2#{obj}\1\e[0;2m\2(#{nest}) > \1\e[0m\2"
          end

          # The continuation prompt for a line after +code+ (the lines so
          # far): as wide as +main+ (default the last main prompt), dim,
          # ending with the open constructs, e.g. "      { do … > ".
          def continuation(code, main = @last)
            width = visible_width(main || '> ')
            opens = open_constructs(code)
            dots = UI.glyphs == :ascii ? '..' : '…'
            tail = opens.empty? ? "#{dots} > " : "#{opens.join(' ')} #{dots} > "
            tail = "#{dots} > " if tail.length > width
            "\1\e[2m\2#{tail.rjust([width, tail.length].max)}\1\e[0m\2"
          end

          # Prompts for Reline's multiline editor (Reline.prompt_proc): the
          # main prompt on the first line, continuation prompts after.
          def lines(buffer)
            buffer.each_index.map { |i| i == 0 ? (@last || '> ') : continuation(buffer[0, i].join("\n") + "\n") }
          end

          # Sets Reline's prompt_proc to .lines.  Called by bin/sound.rb.
          def install!
            ::Reline.prompt_proc = method(:lines) if defined?(::Reline)
          end

          # The constructs open at the end of +code+, outermost first:
          # brackets ('(', '[', '{'), keywords that need an `end`, an
          # unterminated string's quote, or a heredoc's opener.
          def open_constructs(code)
            stack = []
            prev = nil
            line_of = {}
            Ripper.lex(code.to_s).each do |(pos, type, tok, _state)|
              case type
              when :on_lparen then stack << '('
              when :on_lbracket then stack << '['
              when :on_lbrace, :on_tlambeg then stack << '{'
              when :on_embexpr_beg then stack << '#{'
              when :on_rparen, :on_rbracket, :on_rbrace, :on_embexpr_end then stack.pop
              when :on_tstring_beg, :on_regexp_beg, :on_backtick, :on_symbeg, :on_words_beg, :on_qwords_beg, :on_symbols_beg, :on_qsymbols_beg
                stack << tok.strip unless type == :on_symbeg && tok == ':'
              when :on_tstring_end, :on_regexp_end, :on_label_end
                stack.pop
              when :on_heredoc_beg then stack << tok
              when :on_heredoc_end then stack.pop
              when :on_kw
                if tok == 'end'
                  stack.pop
                elsif tok == 'do' && %w[while until for].include?(stack.last) && line_of[stack.length - 1] == pos[0]
                  nil # `while x do`: one construct
                elsif BLOCK_KEYWORDS.include?(tok) || (STATEMENT_KEYWORDS.include?(tok) && (prev.nil? || STATEMENT_START.include?(prev[0]) || prev[0] == :on_kw))
                  line_of[stack.length] = pos[0]
                  stack << tok
                end
              end
              prev = [type, tok] unless %i[on_sp on_comment].include?(type)
            end
            stack
          rescue StandardError
            []
          end

          # Display width of a prompt (escapes and \1 \2 markers removed).
          def visible_width(s)
            s.gsub(/\x01[^\x02]*\x02/, '').gsub(/\e\[[0-9;]*[A-Za-z]/, '').length
          end
        end
      end

      # Enter runs the command when the whole buffer is complete Ruby,
      # wherever the cursor is (Reline's own Enter only submits from the
      # last line, else splits the line at the cursor, so editing a number
      # in a recalled multi-line command added lines); an incomplete buffer
      # gets a new line as before, and Alt-Enter (Reline's own binding)
      # always inserts one.  (Not Ctrl-J: a line typed ahead while a
      # command runs reaches Reline through the tty's ICRNL as "\n", so
      # Ctrl-J can't be told from Enter.)  Prepended to Reline::LineEditor by
      # bin/sound.rb (the console and the tiles' REPL pane alike).
      module EnterSubmits
        def self.install!
          return unless defined?(::Reline::LineEditor)
          ::Reline::LineEditor.prepend(self) unless ::Reline::LineEditor.ancestors.include?(self)
        end

        private

        def ed_newline(key)
          return super unless @is_multiline && !@config.editing_mode_is?(:vi_command)

          process_insert(force: true)
          confirm_multiline_termination ? finish : key_newline(key)
        end
      end
    end
  end
end
