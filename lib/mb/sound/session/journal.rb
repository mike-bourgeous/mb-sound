module MB
  module Sound
    class Session
      # A moment on a Session's two clocks (see design/notes/arrangement.md,
      # contract K1): +frame+ is the session frame (samples at the session
      # rate since the Session was created; monotonic, never reset by seeks,
      # rewinds, pauses, or tempo changes), and +pos+ is the timeline
      # position in whole notes (a Rational).  Either may be nil while it
      # isn't known yet: a change queued for the future has a +pos+ but gets
      # its +frame+ when it lands.
      #
      # +bar_length+ is only for display: stamps print as bar:beat (e.g.
      # "9:1", or "13:2.5" between beats), counting from 1.  The display is
      # never parsed; Ruby input uses Ruby values (`at: bar(9)`, `in: 3.beats`).
      #
      # With a meter map (see Sequence::Transport#meter), +meter_pos+ and
      # +meter_bar+ are where the meter in effect at +pos+ starts and its
      # first bar number, so bar numbers count through earlier meters.
      Stamp = Data.define(:frame, :pos, :bar_length, :meter_pos, :meter_bar) do
        # A Stamp for timeline position +pos+ on +transport+'s meter map.
        def self.at(pos, transport, frame: nil)
          m = pos && transport.meter_at(pos)
          new(frame: frame, pos: pos, bar_length: m ? m.bar_length : transport.bar_length, meter_pos: m&.pos || 0r, meter_bar: m&.bar || 1)
        end

        def initialize(frame: nil, pos: nil, bar_length: 1r, meter_pos: 0r, meter_bar: 1)
          super(frame: frame, pos: pos&.to_r, bar_length: bar_length.to_r, meter_pos: meter_pos.to_r, meter_bar: meter_bar)
        end

        # The bar number (counting from 1) of the position.
        def bar
          pos && ((pos - meter_pos) / bar_length).floor + meter_bar
        end

        # The quarter-note beat within the bar (counting from 1; a Rational
        # between beats).
        def beat
          pos && ((pos - meter_pos) % bar_length) * 4 + 1
        end

        # bar:beat, e.g. "9:1" or "13:2.5"; "?" if the position is unknown.
        def to_s
          return '?' if pos.nil?
          b = beat
          b = b.denominator == 1 ? b.to_i : b.to_f.round(3)
          "#{bar}:#{b}"
        end

        def inspect
          "#<Stamp #{self} frame=#{frame.inspect} pos=#{pos.inspect}>"
        end
      end

      # The Session journal (contract K3 in design/notes/arrangement.md): an
      # append-only, bounded record of every change made to a Session
      # (players added, stopped, resumed, swapped, muted, master effects,
      # undo, ...), with when each was issued and when it lands.  The take
      # (see MB::Sound::Take), the undo list, and later the terminal UI read
      # it.
      #
      # A status change is a new Entry with the same +seq+.  Entries are
      # plain data; #subscribe gets each new one.
      #
      # The render thread never builds entries itself: it pushes small notes
      # onto a queue (#note_landed), which are turned into entries the next
      # time anyone reads or writes the journal.
      class Journal
        # One record in the journal.  "Entry", not "Event": MIDI::Event and
        # Sequence::Event already exist.
        #
        # +seq+ - Integer, unique per Session (shared by a change's entries).
        # +kind+ - :bg, :stop, :resume, :swap, :master, :mute, :unmute,
        #          :solo, :unsolo, :restore, :tempo, :forget, ...
        # +subject+ - The player name (a Symbol or Integer), :master, ...
        # +issued+, +commits+, +lands+ - Stamps (commits/lands are partial
        #                                 or nil until known).
        # +status+ - :queued, :landed, :cancelled, or :failed.
        # +source+ - :console, :schedule, :set, :undo, :replay, ...
        # +line+ - The id of the console line that issued it (see Take), or
        #          nil.
        # +data+ - A Hash of plain values (description, fade, clip, ...).
        # +undoes+ - The +seq+ of the change this one undoes or redoes, or nil.
        Entry = Data.define(:seq, :kind, :subject, :issued, :commits, :lands, :status, :source, :line, :data, :undoes) do
          # Text for the console, e.g. "bg :bass lands 9:1".
          def to_s
            what = kind == :key ? "key #{data.values_at(:root, :mode).compact.map(&:to_s).join(' ')}" : "#{kind} #{subject.inspect}"
            case status
            when :queued then "#{what} lands #{lands} (queued)"
            when :landed then "#{what} landed #{lands}"
            when :cancelled then "#{what} cancelled (was for #{lands})"
            when :failed then "#{what} failed at #{lands}: #{data[:error]}"
            else "#{what} #{status} #{lands}"
            end
          end

          def inspect
            "#<#{self}>"
          end

          def pretty_print(q)
            q.text(inspect)
          end

          # The player name (or other subject), for passing an entry
          # returned by a command back to another command.
          def name
            subject
          end

          def landed?
            status == :landed
          end

          def queued?
            status == :queued
          end
        end

        # The most entries kept (oldest are dropped first).
        DEFAULT_LIMIT = 10_000

        attr_reader :limit

        def initialize(limit: DEFAULT_LIMIT)
          @limit = limit
          @entries = []
          @latest = {}
          @subscribers = []
          @notes = Thread::Queue.new
          @mutex = Mutex.new
          @next_seq = 0
        end

        # A new unique sequence number for a change.
        def next_seq
          @mutex.synchronize { @next_seq += 1 }
        end

        # Appends an entry (or a status change of an existing +seq+).  Returns
        # the entry.
        def add(entry)
          fold
          append(entry)
        end

        # Records from the render thread that change +seq+ landed (or
        # failed, with +error+) at the given stamps.  Only queues a note;
        # see the class comment.
        def note_landed(seq, commits:, lands:, error: nil)
          @notes << [seq, commits, lands, error]
          nil
        end

        # Records from the render thread something that happened by itself
        # (not a change), e.g. a ringing player going to sleep (:rung_out).
        # It becomes a :landed entry with a new +seq+ and +source+ (:session
        # by default; :midi for controller gestures) when the journal is next
        # read.  Only queues a note.
        def note_entry(kind:, subject:, lands:, data: {}, source: :session)
          @notes << [:entry, kind, subject, lands, data, source]
          nil
        end

        # Every entry, oldest first (status changes included as separate
        # entries).
        def entries
          fold
          @mutex.synchronize { @entries.dup }
        end

        # The latest entry for each change, oldest change first.
        def changes
          fold
          @mutex.synchronize { @latest.values }
        end

        # The latest entry for +seq+, or nil.
        def [](seq)
          fold
          @mutex.synchronize { @latest[seq] }
        end

        # Calls the block with every new entry (on whichever thread adds or
        # folds it; never the render thread).  Returns the block for
        # #unsubscribe.
        def subscribe(&block)
          @mutex.synchronize { @subscribers << block }
          block
        end

        def unsubscribe(block)
          @mutex.synchronize { @subscribers.delete(block) }
        end

        # Turns notes from the render thread into entries.  Called before
        # every read and write.
        def fold
          until @notes.empty?
            seq, commits, lands, error, data, source = @notes.pop(true)

            if seq == :entry
              kind, subject = commits, lands
              stamp = error
              append(Entry.new(
                seq: next_seq, kind: kind, subject: subject, issued: stamp, commits: stamp, lands: stamp,
                status: :landed, source: source || :session, line: nil, data: data.freeze, undoes: nil
              ))
              next
            end
            prior = @mutex.synchronize { @latest[seq] }
            next if prior.nil?

            if error
              append(prior.with(status: :failed, commits: commits, lands: lands, data: prior.data.merge(error: error)))
            else
              append(prior.with(status: :landed, commits: commits, lands: lands))
            end
          end
        rescue ThreadError
          # Queue emptied by another reader
        end

        private

        def append(entry)
          subscribers = @mutex.synchronize {
            @entries << entry
            @entries.shift while @entries.length > @limit
            @latest[entry.seq] = entry # an existing seq keeps its place
            @latest.shift while @latest.length > @limit
            @subscribers.dup
          }

          subscribers.each do |s|
            s.call(entry)
          rescue => e
            unsubscribe(s)
            warn "Removed a journal subscriber that raised #{e.class}: #{e.message}"
          end

          entry
        end
      end
    end
  end
end
