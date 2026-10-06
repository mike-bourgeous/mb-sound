module MB
  module Sound
    module MIDI
      # Splits a MIDI Stream's notes among voice lanes, the event-level half
      # of a polyphonic synth.  Each lane (#lanes) is a Stream of its own,
      # read like any stream (by Notes signal nodes, or #reader), that
      # carries at most one note at a time plus every channel-wide event.
      # The allocator reads its input once for all lanes, the first time
      # any lane reads past what it has seen, so lanes may read in any
      # order.  Lane streams keep the input's time base and Rational event
      # times; nothing is delayed.  The same events always give the same
      # allocation (lane idle checks aside; see below).
      #
      # Lanes: +voices+ plus +spares+ (see #spares=).  At most +voices+
      # lanes are active (sounding, or released and possibly still
      # ringing) at once.  A new note goes to a free lane (the one free the
      # longest).  When all voices are active, the +:steal+ chain picks a
      # victim (the first policy that finds one wins):
      # - :same_note - the lane already playing the same (channel, note)
      #   gets the note-on again (a retrigger; no choke).
      # - :oldest_released - the released lane whose note-off came first.
      # - :oldest - the lane whose note started first (sounding or
      #   released).
      # - :quietest - the lane with the lowest Lane#level_check, or without
      #   level checks, released lanes first, then the lowest velocity.
      # If no policy finds a victim, :oldest is used.  The victim gets a
      # :choke event (a 3 ms release; see Event) and the new note goes to a
      # spare lane, so no lane ever carries two notes.  A choking lane
      # becomes free after +:choke_time+ (Envelope::CHOKE_TIME) or when its
      # idle check says so.  With no free lane (no spares, or every spare
      # still choking), the oldest choking lane is reused, or else the
      # victim gets a note-off and the new note directly (a hard steal).
      # +:protect+ (:lowest, :highest, or both in an Array) keeps the lane
      # holding the lowest or highest sounding note from being stolen while
      # another victim exists.
      #
      # Same-note retriggers (+:retrigger+; except for :per_key, these apply
      # when every voice is active and the steal chain includes :same_note,
      # since a note with a voice free always gets a free lane):
      # - :reuse (the default) - the steal chain as given: :same_note
      #   restarts the lane already playing the note.  Its envelopes attack
      #   from their current level to the new note's peak, so a soft
      #   re-strike of a loud ringing note drops to the soft note's level
      #   (see Envelope's +retrigger: :add+ for another answer).
      # - :louder - the lane playing the note is reused only if the new
      #   note is at least as loud as the lane is now: by the lane's
      #   #louder_check if it has one (Synth: no envelope of the voice would
      #   attack downward), else by its #level_check (velocity >= level),
      #   else by velocity (velocity >= the lane's note's velocity; also
      #   used while the lane hasn't yet read its last note event).
      #   Otherwise the note is played as with :new_voice.
      # - :new_voice - the note goes to a free lane (a spare, or the oldest
      #   choking lane), and the victim comes from the rest of the steal
      #   chain (without :same_note, and not a lane playing the same note
      #   unless no other lane can be stolen), so the old note keeps
      #   ringing.  Only when no lane is free does :same_note restart the
      #   lane playing the note, as with :reuse.
      # - :quietest - like :reuse, but when several lanes play the note
      #   (ringing re-strikes), :same_note restarts the quietest of them
      #   (as the :quietest policy measures) instead of the newest.  With
      #   +steal: [:same_note, :quietest, ...]+ and envelopes that add
      #   retriggers, this is Synth's +retrigger: :ring+ for bells.
      # - :per_key - one lane per key, like a string: a note on a key whose
      #   lane is still active (sounding, or released and ringing) always
      #   restarts that lane (the newest, if several), even with voices
      #   free.  Other notes are allocated as usual.  With envelopes that
      #   add retriggers, this is Synth's +retrigger: :string+.
      # Mono mode ignores +:retrigger+.
      #
      # Idle checks: Lane#idle_check (a Proc returning true when the lane's
      # sound has ended, set by +synth+ from the lane's envelopes) lets a
      # released lane become free.  Without one, a released lane counts as
      # active until it is reused (stolen).  Checks are asked only about
      # lanes that have already read every note event sent to them, so a
      # check never sees a graph that hasn't caught up with its events.
      #
      # Polyphonic glide (+:glide_mode+), for synths with portamento:
      # - :last (the default) - every free or released lane gets a :glide
      #   event (see Event) with each new note, so whichever lane plays the
      #   next note glides from the last note played, as on most
      #   polysynths.
      # - :voice - no extra events: each lane glides from its own previous
      #   note (classic analog polysynths).
      # - nil (or :off) - no :glide events either; for synths without
      #   portamento, :voice and nil are the same.
      # Mono mode marks legato notes instead (below).
      #
      # Mono mode (+voices: 1+, or +mono: true+) has one lane and a note
      # stack, so +:spares+ and +:steal+ don't apply.  +:priority+ picks the
      # held note that sounds: :last (the newest, the default), :low, or
      # :high.  A note that takes over while another is held is legato: a
      # note-off of the old note and a note-on of the new one with +legato+
      # true (see Event), at the same time, so Notes keeps the gate up and
      # glides instead of retriggering.  Releasing the sounding note while
      # others are held returns to the one +:priority+ picks, also legato.
      # A note played with nothing held is a normal note-on.  Pass
      # +mono: false+ for one polyphonic voice (stealing with a spare).
      #
      # Event routing:
      # - Notes route by (channel, note), so MPE fits later.  Overlapping
      #   notes on the same key are counted: each note-on gets its own
      #   allocation and note-offs end them oldest first.  Note-offs for
      #   choked notes are dropped.
      # - Poly pressure goes to the lanes holding its key.
      # - Channel-wide events (CCs, bend, channel pressure, program, sysex,
      #   system) go to every lane.
      # - All notes off (CC 123, and 124-127) releases every lane on its
      #   channel (note-offs) and all sound off (CC 120) chokes them; both
      #   CCs then go to every lane.  Reset controllers (121) passes
      #   through (streams already handle controller resets).
      # - Jumps (seek, restart, clip swaps): sources send note-offs for
      #   sounding notes, which release lanes as usual; each lane's
      #   #generation follows the input's.
      #
      # Example:
      #     alloc = MB::Sound::MIDI::Allocator.new('song.mid', voices: 4)
      #     alloc.lanes[0].reader.next(1)   # the first lane's events in the first second
      class Allocator
        include GraphNode::Nameable
        include GraphNode::Traversable

        # The default steal chain.
        DEFAULT_STEAL = [:same_note, :oldest_released, :oldest].freeze

        # Every steal policy (see the class description).
        STEAL_POLICIES = [:same_note, :oldest_released, :oldest, :quietest].freeze

        # Notes that +:protect+ can keep from being stolen.
        PROTECT = [:lowest, :highest].freeze

        # Mono mode note priorities (see the class description).
        PRIORITIES = [:last, :low, :high].freeze

        # Same-note retrigger modes (see the class description).
        RETRIGGER_MODES = [:reuse, :louder, :new_voice, :quietest, :per_key].freeze

        # Polyphonic glide modes (see the class description).
        GLIDE_MODES = [:last, :voice, nil].freeze

        # Event types that change whether a lane is sounding (see #idle?).
        NOTE_TYPES = [:note_on, :note_off, :choke].freeze

        # One voice lane: a Stream of the notes given to the lane plus every
        # channel-wide event.  Also shows the lane's allocation state.
        class Lane < Stream
          # The Allocator that feeds this lane.
          attr_reader :allocator

          # The lane's index in Allocator#lanes.
          attr_reader :index

          # A Proc (or anything with #call) that returns true once the
          # lane's sound has ended (all of its envelopes are idle), so a
          # released lane can be reused without a choke.  Set by +synth+.
          attr_accessor :idle_check

          # A Proc returning the lane's current level, for the :quietest
          # steal policy and +retrigger: :louder+ (optional).
          attr_accessor :level_check

          # A Proc taking a note-on velocity (0..1) that returns true if a
          # note at that velocity would bring the lane at least as high as
          # it is now, for +retrigger: :louder+ (optional; set by Synth).
          attr_accessor :louder_check

          def initialize(allocator, index)
            @allocator = allocator
            @index = index
            super(LaneSource.new(allocator, index))
          end

          # True if the lane has an event before stream time +to+ that its
          # readers haven't read yet (reading the allocator's input up to
          # +to+ first, as a read of the lane would).  Used by Synth to wake
          # a lane it skips while idle.
          def pending_before?(to)
            @allocator.advance(to)
            (!@log.empty? && @log.first.time < to) || source.pending_before?(to)
          end

          # The result of the idle check, or nil if there isn't one.
          def idle?
            @idle_check ? !!@idle_check.call : nil
          end

          # The lane's allocation state as of the last event the allocator
          # read: :free, :sounding, :released, or :choking.
          def state
            @allocator.lane_state(@index).state
          end

          # The note the lane plays or last played (nil if never used).
          def note
            @allocator.lane_state(@index).note
          end

          # The channel of #note.
          def channel
            @allocator.lane_state(@index).channel
          end

          def to_s
            "MIDI lane #{@index}"
          end
        end

        # The Source of a Lane stream: events the allocator queued for the
        # lane.  A Transform of the allocator's input (so streams treat it
        # as derived, e.g. no second pitch bend range tracker, and seeks go
        # to the root source), but it doesn't read the input itself: the
        # allocator reads it once for every lane.
        class LaneSource < Transform
          attr_reader :index

          def initialize(allocator, index)
            # Not calling super, which would open a reader of the input
            @allocator = allocator
            @index = index
            @parent = allocator.stream
            @position = allocator.position
            @queue = []
            @node_type_name = "lane #{index}"
          end

          # True once the allocator's input has ended and this lane has
          # read every event sent to it.
          def ended?
            @allocator.ended? && @queue.empty?
          end

          def sources
            { allocator: @allocator }
          end

          # True if an event queued for the lane is before stream time +to+
          # (see Lane#pending_before?).
          def pending_before?(to)
            !@queue.empty? && @queue.first.time < to
          end

          # Used by Allocator to send an event to this lane (in time order).
          def push(event)
            @queue << event
          end

          private

          def read_events(from, to)
            @allocator.advance(to)
            count = @queue.bsearch_index { |e| e.time >= to } || @queue.length
            return Stream::NO_EVENTS if count == 0

            out = @queue.shift(count)
            out.select! { |e| e.time >= from } if !out.empty? && out.first.time < from
            out
          end
        end

        # Allocation state of one lane (internal; see Lane#state).
        class LaneState
          attr_accessor :index, :state, :channel, :note, :velocity, :slots,
            :on_seq, :off_seq, :free_seq, :choke_end, :last_time

          def initialize(index)
            @index = index
            @state = :free
            @slots = []
            @free_seq = -1
            @last_time = nil
          end

          def key
            [@channel, @note]
          end

          def active?
            @state == :sounding || @state == :released
          end
        end

        # One note-on's allocation, queued per (channel, note) so note-offs
        # end overlapping notes oldest first.  +voice+ is nil once the note
        # was choked or released another way.  Compared by identity (a
        # Struct would make two notes on one lane equal).
        class Slot
          attr_accessor :voice

          def initialize(voice)
            @voice = voice
          end
        end

        # The input Stream.
        attr_reader :stream

        # The lane Streams (Lane objects).
        attr_reader :lanes

        # The maximum number of active lanes.
        attr_reader :voices

        # The number of spare lanes in use (see #spares=).
        attr_reader :spares

        # The largest #spares allowed (the spares given to the constructor).
        attr_reader :max_spares

        # The steal chain (an Array of policies).
        attr_reader :steal

        # Notes protected from stealing (an Array, maybe empty).
        attr_reader :protect

        # Seconds a choking lane takes to become free.
        attr_reader :choke_time

        # The mono mode note priority.
        attr_reader :priority

        # The polyphonic glide mode (:last, :voice, or nil).
        attr_reader :glide_mode

        # The same-note retrigger mode (:reuse, :louder, or :new_voice).
        attr_reader :retrigger

        # The input stream time where lanes start.
        attr_reader :position

        # Stream time up to which the input has been read.
        attr_reader :read_to

        # +stream+ is anything Stream.for accepts (a Stream, Source, Clip,
        # MIDIFile, or filename).  See the class description for
        # +:voices+, +:spares+, +:steal+ (a policy or Array of policies),
        # +:protect+, +:mono+ (true by default for one voice), and
        # +:priority+, +:glide_mode+, and +:retrigger+.  +:choke_time+ is the
        # seconds after a :choke event when a lane counts as free.
        def initialize(
          stream, voices: 8, spares: 2, steal: DEFAULT_STEAL, protect: nil, mono: nil, priority: :last,
          glide_mode: :last, retrigger: :reuse, choke_time: Envelope::CHOKE_TIME
        )
          unless voices.is_a?(Integer) && voices >= 1
            raise ArgumentError, "Voices must be a positive Integer (got #{voices.inspect})"
          end
          unless spares.is_a?(Integer) && spares >= 0
            raise ArgumentError, "Spares must be a non-negative Integer (got #{spares.inspect})"
          end

          @steal = Array(steal).freeze
          bad = @steal - STEAL_POLICIES
          raise ArgumentError, "Unknown steal policies #{bad} (use #{STEAL_POLICIES})" unless bad.empty?

          @protect = Array(protect).freeze
          bad = @protect - PROTECT
          raise ArgumentError, "Unknown protect values #{bad} (use #{PROTECT})" unless bad.empty?

          unless PRIORITIES.include?(priority)
            raise ArgumentError, "Unknown note priority #{priority.inspect} (use #{PRIORITIES})"
          end

          glide_mode = nil if glide_mode == :off || glide_mode == false
          unless GLIDE_MODES.include?(glide_mode)
            raise ArgumentError, "Unknown glide mode #{glide_mode.inspect} (use #{GLIDE_MODES} or :off)"
          end
          @glide_mode = glide_mode

          unless RETRIGGER_MODES.include?(retrigger)
            raise ArgumentError, "Unknown retrigger mode #{retrigger.inspect} (use #{RETRIGGER_MODES})"
          end
          @retrigger = retrigger

          @mono = mono.nil? ? voices == 1 : !!mono
          raise ArgumentError, "Mono mode has one voice (got #{voices})" if @mono && voices != 1
          spares = 0 if @mono

          @voices = voices
          @spares = spares
          @max_spares = spares
          @priority = priority
          @stack = []
          @playing = nil
          @choke_time = choke_time.to_r.rationalize(Rational(1, 10**12))

          @stream = Stream.for(stream)
          @input = @stream.reader
          @position = @input.cursor
          @read_to = @position

          lane_count = voices + spares
          @voice_states = Array.new(lane_count) { |idx| LaneState.new(idx) }
          @lanes = Array.new(lane_count) { |idx| Lane.new(self, idx) }
          @lane_sources = @lanes.map(&:source)

          @held = {}
          @seq = 0
          @node_type_name = "allocator(#{voices} voices)"
        end

        # Changes the number of spare lanes in use (from 0 to #max_spares),
        # e.g. to drop a spare under sustained CPU overload.  Lanes beyond
        # +voices + spares+ get no new notes but finish what they play.
        def spares=(count)
          unless count.is_a?(Integer) && count.between?(0, @max_spares)
            raise ArgumentError, "Spares must be an Integer from 0 to #{@max_spares} (got #{count.inspect})"
          end
          @spares = count
        end

        # True in mono mode (see the class description).
        def mono?
          @mono
        end

        # The allocation state of lane +index+ (see Lane#state).
        def lane_state(index)
          @voice_states[index]
        end

        # The number of active lanes (sounding or released) as of the last
        # event read.
        def active_count
          @voice_states.count(&:active?)
        end

        # True once the input has ended and been read.
        def ended?
          @input.ended?
        end

        # The input's generation (see Stream#generation).
        def generation
          @stream.generation
        end

        def music_end
          @stream.music_end
        end

        def sources
          { input: @stream }
        end

        def to_s
          node_type_name
        end

        # Reads the input up to +to+ seconds and sends its events to the
        # lanes.  Called by lanes when they read.
        def advance(to)
          return if to <= @read_to

          events = @input.events(@read_to, to)
          @read_to = to
          events.each do |e| process(e) end
        end

        private

        # Sends +event+ to lane +voice+.
        def send_to(voice, event)
          voice.last_time = event.time if NOTE_TYPES.include?(event.type)
          @lane_sources[voice.index].push(event)
        end

        def broadcast(event)
          @lane_sources.each do |s| s.push(event) end
        end

        def next_seq
          @seq += 1
        end

        def process(e)
          case e.type
          when :note_on then @mono ? mono_on(e) : note_on(e)
          when :note_off then @mono ? mono_off(e) : note_off(e)

          when :poly_pressure
            if @mono
              send_to(@voice_states[0], e) if @playing && @playing.channel == e.channel && @playing.note == e.note
            else
              @held[[e.channel, e.note]]&.each { |slot| send_to(slot.voice, e) if slot.voice }
            end

          when :cc
            if e.all_notes_off?
              @mono ? mono_clear(e.channel, e.time, choke: false) : release_channel(e.channel, e.time)
            elsif e.all_sound_off?
              @mono ? mono_clear(e.channel, e.time, choke: true) : choke_channel(e.channel, e.time)
            end
            broadcast(e)

          when :choke, :glide
            # Allocation events from another allocator's lane mean nothing here

          else
            broadcast(e)
          end
        end

        def note_on(e)
          key = [e.channel, e.note]
          refresh(e.time)

          if @retrigger == :per_key && (same = same_note_voice(key))
            restrike(same, e)
            return
          end

          if active_count >= @voices
            return if new_voice_retrigger(key, e)

            policy, victim = steal_victim(key)

            if policy == :same_note
              restrike(victim, e)
              return
            end

            target = free_lane || oldest_choking
            if target
              choke(victim, e.time)
            else
              hard_steal(victim, e.time)
              target = victim
            end
          else
            target = free_lane || oldest_choking || oldest_active
            hard_steal(target, e.time) if target.active?
          end

          start(target, e)
        end

        def note_off(e)
          key = [e.channel, e.note]
          slots = @held[key]
          return unless slots

          slot = slots.shift
          @held.delete(key) if slots.empty?

          voice = slot.voice
          return unless voice

          voice.slots.delete(slot)
          send_to(voice, e)

          if voice.slots.empty?
            voice.state = :released
            voice.off_seq = next_seq
          end
        end

        # Starts note-on +e+ on +voice+, which carries no note.
        def start(voice, e)
          voice.state = :sounding
          voice.channel = e.channel
          voice.note = e.note
          voice.velocity = e.velocity
          voice.on_seq = next_seq
          voice.off_seq = nil
          voice.choke_end = nil
          add_slot(voice, e)
          send_to(voice, e)
          glide_others(voice, e)
        end

        # For +retrigger: :louder+ or :new_voice+, with every voice active:
        # plays note-on +e+ for +key+ on the lane already playing it (if
        # :louder finds it louder) or on a free lane, choking a victim from
        # the steal chain without :same_note.  Returns true if it handled
        # the note, false to leave it to the normal steal chain (:reuse, no
        # lane playing the key, :same_note not in the chain, or no free
        # lane).
        def new_voice_retrigger(key, e)
          return false unless (@retrigger == :louder || @retrigger == :new_voice) && @steal.include?(:same_note)

          same = same_note_voice(key)
          return false unless same

          if @retrigger == :louder && louder?(same, e)
            restrike(same, e)
            return true
          end

          target = free_lane || oldest_choking
          return false unless target

          _, victim = steal_victim(key, same_note: false)
          choke(victim, e.time)
          start(target, e)
          true
        end

        # The active lane playing +key+ that started last, or nil.
        def same_note_voice(key)
          @voice_states.select { |v| v.active? && v.key == key }.max_by(&:on_seq)
        end

        # True if note-on +e+ is at least as loud as lane +voice+ is now
        # (see :louder in the class description).
        def louder?(voice, e)
          lane = @lanes[voice.index]
          caught_up = voice.last_time.nil? || voice.last_time < @lane_sources[voice.index].position

          if caught_up && lane.louder_check
            !!lane.louder_check.call(e.velocity)
          elsif caught_up && lane.level_check
            e.velocity >= lane.level_check.call.to_f
          else
            e.velocity >= (voice.velocity || 0)
          end
        end

        # Sends note-on +e+ again to +voice+, which plays the same key.
        def restrike(voice, e)
          voice.state = :sounding
          voice.velocity = e.velocity
          voice.on_seq = next_seq
          voice.off_seq = nil
          add_slot(voice, e)
          send_to(voice, e)
          glide_others(voice, e)
        end

        # With glide mode :last, tells every free or released lane other
        # than +voice+ to glide from note-on +e+'s note.
        def glide_others(voice, e)
          return unless @glide_mode == :last

          @voice_states.each do |v|
            next if v.equal?(voice) || !(v.state == :free || v.state == :released)
            send_to(v, Event.glide(e.note, channel: e.channel, time: e.time))
          end
        end

        def add_slot(voice, e)
          slot = Slot.new(voice)
          voice.slots << slot
          (@held[[e.channel, e.note]] ||= []) << slot
        end

        # Detaches +voice+ from its held notes, so their note-offs are
        # dropped.
        def detach(voice)
          voice.slots.each do |slot| slot.voice = nil end
          voice.slots.clear
        end

        def choke(voice, time)
          detach(voice)
          send_to(voice, Event.choke(voice.note, channel: voice.channel, time: time))
          voice.state = :choking
          voice.choke_end = time + @choke_time
        end

        # Ends the note on +voice+ with a note-off so it can take a new note
        # directly (when no spare lane is free).
        def hard_steal(voice, time)
          count = voice.slots.length
          detach(voice)
          count.times do
            send_to(voice, Event.note_off(voice.note, channel: voice.channel, time: time))
          end
          free(voice)
        end

        def free(voice)
          voice.state = :free
          voice.free_seq = next_seq
        end

        # Frees choking lanes whose choke is over and released or choking
        # lanes whose idle check says so.
        def refresh(time)
          @voice_states.each do |v|
            case v.state
            when :choking
              free(v) if time >= v.choke_end || idle?(v)
            when :released
              free(v) if idle?(v)
            end
          end
        end

        # Asks lane +voice+'s idle check, only if the lane has read every
        # note event sent to it.
        def idle?(voice)
          lane = @lanes[voice.index]
          return false unless lane.idle_check
          return false if voice.last_time && voice.last_time >= @lane_sources[voice.index].position
          lane.idle? == true
        end

        # The free lane (among lanes in use) that has been free the longest.
        def free_lane
          limit = @voices + @spares
          @voice_states.select { |v| v.state == :free && v.index < limit }.min_by { |v| [v.free_seq, v.index] }
        end

        def oldest_choking
          @voice_states.select { |v| v.state == :choking }.min_by(&:choke_end)
        end

        def oldest_active
          @voice_states.select(&:active?).min_by(&:on_seq)
        end

        # Returns [policy, voice] for the lane to steal for a note on +key+.
        # With +:same_note+ false, skips the :same_note policy and lanes
        # playing +key+ (unless no other lane can be stolen).
        def steal_victim(key, same_note: true)
          active = @voice_states.select(&:active?)
          candidates = unprotected(active)
          policies = @steal

          unless same_note
            policies = @steal - [:same_note]
            others = candidates.reject { |v| v.key == key }
            candidates = others unless others.empty?
          end

          policies.each do |policy|
            victim = case policy
                     when :same_note
                       same = active.select { |v| v.key == key }
                       @retrigger == :quietest ? same.min_by { |v| [quietness(v), v.on_seq] } : same.max_by(&:on_seq)
                     when :oldest_released
                       candidates.select { |v| v.state == :released }.min_by(&:off_seq)
                     when :oldest
                       candidates.min_by(&:on_seq)
                     when :quietest
                       candidates.min_by { |v| [quietness(v), v.on_seq] }
                     end
            return [policy, victim] if victim
          end

          [:oldest, candidates.min_by(&:on_seq)]
        end

        # Removes lanes holding protected notes from +active+, unless that
        # would leave nothing.
        def unprotected(active)
          return active if @protect.empty?

          sounding = active.select { |v| v.state == :sounding }
          return active if sounding.length < 2

          keep = []
          keep << sounding.min_by { |v| [Allocator.pitch_value(v.note), v.on_seq] } if @protect.include?(:lowest)
          keep << sounding.max_by { |v| [Allocator.pitch_value(v.note), -v.on_seq] } if @protect.include?(:highest)

          rest = active - keep
          rest.empty? ? active : rest
        end

        # A sort key for the :quietest policy.
        def quietness(voice)
          check = @lanes[voice.index].level_check
          return [0, check.call.to_f] if check
          [voice.state == :released ? 0 : 1, voice.velocity || 0]
        end

        # Mono mode note-on: pushes the note on the stack, and plays it if
        # it takes over (legato if another note was sounding).
        def mono_on(e)
          @stack << e
          target = mono_target
          prev = @playing
          return if prev && target.equal?(prev)

          voice = @voice_states[0]
          if prev
            send_to(voice, Event.note_off(prev.note, channel: prev.channel, time: e.time))
            mono_play(voice, target, e.time, legato: true)
          else
            mono_play(voice, target, e.time, legato: false)
          end
        end

        # Mono mode note-off: removes the oldest matching note from the
        # stack, and if it was sounding, returns to the next held note
        # (legato) or releases the lane.
        def mono_off(e)
          idx = @stack.index { |x| x.channel == e.channel && x.note == e.note }
          return unless idx

          removed = @stack.delete_at(idx)
          return unless removed.equal?(@playing)

          voice = @voice_states[0]
          send_to(voice, e)

          if @stack.empty?
            @playing = nil
            voice.state = :released
            voice.off_seq = next_seq
          else
            mono_play(voice, mono_target, e.time, legato: true)
          end
        end

        # Sends held note-on +entry+ to the mono lane at +time+.
        def mono_play(voice, entry, time, legato:)
          @playing = entry
          voice.state = :sounding
          voice.channel = entry.channel
          voice.note = entry.note
          voice.velocity = entry.velocity
          voice.on_seq = next_seq
          event = entry.time == time ? entry : entry.at(time)
          send_to(voice, legato ? event.with(legato: true) : event)
        end

        # The held note that sounds in mono mode, by #priority (the newest
        # wins ties).
        def mono_target
          case @priority
          when :last then @stack.last
          when :low then @stack.each_with_index.min_by { |x, idx| [Allocator.pitch_value(x.note), -idx] }.first
          when :high then @stack.each_with_index.max_by { |x, idx| [Allocator.pitch_value(x.note), idx] }.first
          end
        end

        # Mono mode all notes off (CC 123) or all sound off (CC 120, with
        # +:choke+): forgets held notes on +channel+ and ends the sounding
        # one if it's on that channel.
        def mono_clear(channel, time, choke:)
          @stack.reject! { |x| x.channel == channel }
          return unless @playing&.channel == channel

          voice = @voice_states[0]
          @playing = nil
          if choke
            send_to(voice, Event.choke(voice.note, channel: channel, time: time))
            voice.state = :choking
            voice.choke_end = time + @choke_time
          else
            send_to(voice, Event.note_off(voice.note, channel: channel, time: time))
            voice.state = :released
            voice.off_seq = next_seq
          end
        end

        # Sends note-offs to every lane sounding on +channel+ (CC 123).
        def release_channel(channel, time)
          @voice_states.each do |v|
            next unless v.state == :sounding && v.channel == channel
            count = v.slots.length
            detach(v)
            count.times do send_to(v, Event.note_off(v.note, channel: channel, time: time)) end
            v.state = :released
            v.off_seq = next_seq
          end
          forget_channel(channel)
        end

        # Chokes every active lane on +channel+ (CC 120).
        def choke_channel(channel, time)
          @voice_states.each do |v|
            choke(v, time) if v.active? && v.channel == channel
          end
          forget_channel(channel)
        end

        # Forgets held notes on +channel+, so a later note on the same key
        # isn't ended by an old note-off that never arrives (some
        # sequencers send CC 123 instead of note-offs).
        def forget_channel(channel)
          @held.delete_if { |(ch, _), _| ch == channel }
        end

        public

        # Returns a number for comparing note pitches (MIDI note numbers):
        # Numerics as they are, Notes by number, and Pitches from their
        # frequency at A4 = 440 Hz.
        def self.pitch_value(note)
          case note
          when Numeric then note
          when Note then note.number
          when Pitch then 69 + 12 * Math.log2(note.frequency / 440.0)
          else note.to_f
          end
        end
      end
    end
  end
end
