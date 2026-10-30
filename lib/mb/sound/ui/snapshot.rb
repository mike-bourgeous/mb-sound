module MB
  module Sound
    module UI
      # The slow, structural part of what panes show (tracks, scenes, queued
      # changes, the form, knob ranges), gathered a few times a second on
      # the painter thread by Poll from public APIs that never take the
      # render lock.  Frozen plain data.
      Slow = Data.define(:tracks, :scenes, :scene, :queued, :recording, :armed, :form, :knob_specs, :buses, :routes, :landed, :clips, :midi,
                         :matrix, :racks, :clocks, :inspector, :render_source, :cue_heard) do
        # (The fields ux-1 r3 added default to empty: +buses+ BusInfos,
        # +routes+ (player => { to:, send: { bus => level } }), +landed+
        # LandedInfos (newest last), +clips+ ClipInfos, +midi+ a MidiInfo;
        # UI round 4: +matrix+ a MatrixInfo (or nil), +racks+ Rack::RackInfos;
        # time-automation: +clocks+ ClockInfos; sound-design-ui-1: +inspector+
        # an Inspect::InspectInfo while a pane needs :inspect, else nil;
        # sound-design-ui-2: +render_source+ the inspected track's
        # PatchRender::Source while a pane needs :render, else nil;
        # ui-scaffold-1: +cue_heard+ Session#cue_heard?, where auditions play)
        def initialize(tracks:, scenes:, scene:, queued:, recording:, armed:, form:, knob_specs:, buses: [].freeze, routes: {}.freeze,
                       landed: [].freeze, clips: [].freeze, midi: nil, matrix: nil, racks: [].freeze, clocks: [].freeze, inspector: nil, render_source: nil,
                       cue_heard: false)
          super
        end

        def self.empty
          @empty ||= new(tracks: [].freeze, scenes: [].freeze, scene: nil, queued: [].freeze, recording: [].freeze, armed: [].freeze, form: nil, knob_specs: {}.freeze)
        end
      end

      # A Session clock (time-automation): +name+, +what+ in words ("31.1 s
      # period"), its +unit+ (:cycles or :whole_notes), and where it is
      # when polled: +count+ (whole cycles or bars from the start, from 1)
      # and +phase+ (0...1 of the cycle or bar).
      ClockInfo = Data.define(:name, :what, :unit, :count, :phase) do
        # "tide 31.1 s period 4+0.42"
        def to_s = "#{name} #{what} #{count}+#{format('%.2f', phase)}"
      end

      # A bus (Session#bus_info): +name+, where it goes (+to+), its chain's
      # +description+, +asleep+, +muted+, the players sending a level into
      # it (+sends+) and routed to it (+sources+, `to:`).  A send and a
      # `to:` are the same thing at two depths: a level into the bus, or
      # all of the player.
      BusInfo = Data.define(:name, :to, :description, :asleep, :muted, :sends, :sources) do
        def initialize(name:, to:, description:, asleep:, muted:, sends: [].freeze, sources: [].freeze)
          super
        end
      end

      # A change that landed (the journal): +seq+, +kind+, +subject+, where
      # it landed (+lands+, bar:beat text; +pos+ whole notes), and +at+ (the
      # clock when the poll heard it land; nil for changes from before the
      # UI started).
      LandedInfo = Data.define(:seq, :kind, :subject, :lands, :pos, :at)

      # A clip the set uses: +name+, +kind+ (seq, clip, kit, grid), +bars+
      # (its length), +pattern+ (a one-line picture of its onsets), +used+
      # (where: track names and scene names).  UI round 4 (the clip
      # matrix and detail pane): +key+ (a stable display key: the name, or
      # "bass#3" for an unnamed clip in slot 3 of track :bass), +loop+,
      # +length+ (whole notes), +events+ (NoteInfos), +ruby+ (its to_ruby
      # text, or nil), +range+ (lowest..highest note, or nil).  ux-r4b:
      # +history+ (a `tweak` version's lineage: the clip its tweaks started
      # from, then each transform as tweak takes it, e.g. ["bass_a",
      # "transpose: 2", ":reverse"]; empty for other clips).
      ClipInfo = Data.define(:name, :kind, :bars, :pattern, :used, :key, :loop, :length, :events, :ruby, :range, :history) do
        def initialize(name:, kind:, bars:, pattern:, used:, key: nil, loop: false, length: 0r, events: [].freeze, ruby: nil, range: nil, history: [].freeze)
          super
        end
      end

      # A note of a clip (ClipInfo#events), in whole notes: +start+,
      # +length+, +note+ (a MIDI note number, or nil), +velocity+ (0..1),
      # +row+ (a kit row's name, or nil), +marks+ (Symbols: :accent,
      # :slide, :flam, :fill, :pitch).
      NoteInfo = Data.define(:start, :length, :note, :velocity, :row, :marks)

      # The clip matrix (Poll): +tracks+ (LaneInfos) and +scenes+
      # (SceneInfos).
      MatrixInfo = Data.define(:tracks, :scenes)

      # A track in the clip matrix: +name+, +q+ (launch quantization as
      # text), +state+ (:playing or :stopped as of landed changes; see
      # Snapshot#lane_state for the player's state per buffer), +playing+
      # (the slot index playing, or nil), +queued+ (LaunchInfos), +slots+
      # (ClipInfos, append-only: an index never changes in a session).
      LaneInfo = Data.define(:name, :q, :state, :playing, :queued, :slots)

      # A launch waiting to land: +seq+ (journal), +kind+ (:launch, :stop,
      # :scene), +slot+ (index, or nil), where it +lands+ (bar:beat text)
      # and +pos+ (whole notes).
      LaunchInfo = Data.define(:seq, :kind, :slot, :lands, :pos)

      # A scene row of the clip matrix: +name+, +cells+ ({ track => slot
      # index, :stop, or :keep }), +current+, +queued+ (a LaunchInfo or nil).
      SceneInfo = Data.define(:name, :cells, :current, :queued)

      # A note held on one of the Session's MIDI inputs (Snapshot#notes):
      # +note+ and +velocity+ (0..127), +channel+ (0-based), +source+
      # (:input, or the label of an added source such as :keyboard), the
      # MidiInput's name (+input+, nil for the default), and where its
      # note-on landed (+frame+, +pos+).
      HeldNote = Data.define(:note, :velocity, :channel, :source, :input, :frame, :pos)

      # Recent MIDI (Session#midi_log, read without the render lock):
      # +events+ ([stamp text, source name, kind, text], newest last), +ccs+
      # ({ number => last value 0..127 }), +mapped+ ([knob name, cc number]).
      MidiInfo = Data.define(:events, :ccs, :mapped)

      # A track: +name+, +q+ (its launch quantization, as text), +clip+ (the
      # clip's name, or "graph"), +armed+, +trigger+ (true for a trigger track,
      # heard only by sidechains; SidechainMethods#sidechain).
      # +instrument+: the Library::Entry the track's patch plays (track
      # :bass, L.inst.x; nil for patch blocks and graphs; ui-scaffold-1,
      # the library picker marks it).
      TrackInfo = Data.define(:name, :q, :clip, :armed, :trigger, :instrument) do
        def initialize(name:, q:, clip:, armed:, trigger: false, instrument: nil)
          super
        end
      end

      # A queued change: +kind+ (:add, :stop, :knob, ...), +subject+, and
      # where it +lands+ (bar:beat text) and its timeline position +pos+
      # (whole notes, or nil).
      QueuedInfo = Data.define(:seq, :kind, :subject, :lands, :pos)

      # A recording: the track +name+ and where it ends (+ends+, bar:beat
      # text; +pos+ in whole notes), or +queued+ if it hasn't started.
      RecordingInfo = Data.define(:name, :ends, :pos, :queued)

      # The form playing: +section+, +pass+, the section's start and end
      # (+from+, +to+: timeline positions, whole notes), the +next+ section
      # and its start (+next_at+, bar:beat), and whether it is +committed+,
      # +looping+, or +ended+.
      FormInfo = Data.define(:section, :pass, :from, :to, :next, :next_at, :committed, :looping, :ended)

      # Master meter readings over one snapshot's buffers: +peak+ and +rms+
      # (Arrays, one dBFS value per channel), +true_peak+ (dBTP, the
      # loudest channel's oversampled peak) and short-term loudness
      # +lufs_s+ (LUFS, BS.1770 over the last 3 s).
      MasterLevels = Data.define(:peak, :rms, :true_peak, :lufs_s)

      # The CPU used by one part: +name+, +kind+ (:player, :bus, :master),
      # +state+ (see Session::UIFeed::UIPart), and +load+ (its share of the
      # snapshot's audio time, e.g. 0.12 for 12%).
      PartLoad = Data.define(:name, :kind, :state, :load)

      # A knob's +value+ as of the snapshot, with its +spec+
      # (GraphNode::Knob::Spec: range, curve, unit).
      KnobValue = Data.define(:name, :value, :spec)

      # What every pane draws from: published by the render thread once per
      # buffer while the painter keeps up ("snapshots in, cells out"), so
      # the painter never touches the Session.  Frozen plain data (a
      # Ractor or another process could draw from it too).
      #
      # Fast fields: +seq+ (publish count), +time+ (MB::U.clock_now when
      # published), +frame+, +pos+ (timeline position in whole notes),
      # +bar+, +beat+ (Rational, counting from 1), +bpm+, +bar_length+
      # (whole notes), +playing+, +sample_rate+, +buffer_size+, +load+ and
      # +load_max+ (render time over buffer time, mean and worst over the
      # snapshot's buffers), +parts+ (PartLoads), +master+ (MasterLevels,
      # or nil without a meter pane), +scope+ (frozen Numo::SFloats, one per
      # channel, the latest samples; nil without a scope pane),
      # +underruns+ (the output's count, or nil), +knobs+ (KnobValues),
      # +latency+ (seconds from this buffer's write to the speakers: the
      # output's queue and the card's buffer; 0 without a sound card).
      # +slow+ is the latest Slow.
      #
      # UI round 4 (contract in design/notes/terminal_ui.md): +bus_levels+
      # ({ bus => BusLevels }) and +send_levels+ ({ [player, bus] =>
      # SendLevel }) while a pane needs :buses (else nil); +notes+ (the
      # HeldNotes on the Session's MIDI inputs, always); +sounding+
      # (reserved for notes after a scale transform; nil).
      Snapshot = Data.define(
        :seq, :time, :frame, :pos, :bar, :beat, :bpm, :bar_length, :playing,
        :sample_rate, :buffer_size, :load, :load_max, :parts, :master, :scope,
        :underruns, :knobs, :slow, :latency, :bus_levels, :send_levels, :notes, :sounding
      ) do
        # Defaults for every field (a stopped transport at bar 1).
        def self.defaults
          {
            seq: 0, time: 0.0, frame: 0, pos: 0r, bar: 1, beat: 1r, bpm: 120, bar_length: 1r, playing: false,
            sample_rate: 48000, buffer_size: 800, load: nil, load_max: nil, parts: [].freeze, master: nil, scope: nil,
            underruns: nil, knobs: [].freeze, slow: Slow.empty, latency: 0.0,
            bus_levels: nil, send_levels: nil, notes: [].freeze, sounding: nil,
          }
        end

        # A snapshot with defaults for the fields not given (for specs,
        # demos, and the painter before the first buffer).
        def self.fake(**fields)
          new(**defaults, **fields)
        end

        # The players among #parts.
        def players = parts.select { |p| p.kind == :player }

        # bar:beat with a whole beat ("17:3").
        def stamp = "#{bar}:#{beat.floor}"

        # The time signature ("4/4", "7/8").
        def meter = Sequence::Transport.meter_label(bar_length)

        def tracks = slow.tracks
        def scenes = slow.scenes
        def scene = slow.scene
        def queued = slow.queued
        def recording = slow.recording
        def armed = slow.armed
        def form = slow.form
        def buses = slow.buses
        def routes = slow.routes
        def landed = slow.landed
        def clips = slow.clips
        def midi = slow.midi
        def matrix = slow.matrix
        def racks = slow.racks
        def clocks = slow.clocks
        def inspector = slow.inspector
        def render_source = slow.render_source
        def cue_heard = slow.cue_heard

        # Track +name+'s state for the clip matrix: the player's state this
        # buffer (#parts: :playing, :starting, :stopping, :ringing,
        # :fading, :muted, :asleep), else :stopped.
        def lane_state(name)
          parts.find { |p| p.kind == :player && p.name == name }&.state || :stopped
        end

        # When what this snapshot shows is heard: its time plus the
        # output's latency (ux-1 r3 item 32b).
        def heard_at = time + latency.to_f
      end

      # Master meters on the render thread (see MasterLevels): sample peaks
      # and RMS per channel, true peak (BS.1770 Annex 2, in C), and
      # short-term loudness from K-weighted energy in blocks of at least
      # 100 ms (so its window moves in block steps).
      class MasterMeter
        # Blocks kept for short-term loudness (3 s of 100 ms blocks).
        BLOCKS = 30

        def initialize(channels, sample_rate)
          @channels = channels
          @sample_rate = sample_rate.to_f
          @filters = Array.new(channels) { Loudness.k_weighting(@sample_rate) }
          @weights = Loudness.default_weights(channels)
          @phases = Loudness::TruePeak::MATRICES[:annex2]
          @history_length = @phases.shape[1] - 1
          @history = Array.new(channels) { Numo::DFloat.zeros(@history_length) }
          # The native path's buffers (see .native): history plus the new
          # samples, the widened samples, and the kernel's results
          @ext = Array.new(channels)
          @x = Array.new(channels)
          @result = [0.0, 0.0, 0.0]
          @block_length = (@sample_rate * 0.1).round
          @block_energy = 0.0
          @block_frames = 0
          @energies = []
          @frames = []
          reset_interval
        end

        # Adds one buffer (an Array of Numo::SFloat, one per channel).
        def process(mix)
          n = mix[0].length
          return if n == 0

          c = 0
          while c < @channels
            buf = mix[c] || mix[0]
            if MasterMeter.native && buf.is_a?(Numo::SFloat) && buf.contiguous?
              # Allocation-free (FastLoudness.meter_block, the same values)
              x = native_block(c, buf, n)
              peak, sumsq, tp = @result
            else
              x = Numo::DFloat.cast(buf)
              x = x.dup if x.equal?(buf)

              peak = x.abs.max
              sumsq = (x * x).sum

              ext = history_of(c).concatenate(x)
              tp = FastLoudness.true_peak(ext, n, @phases)
              @history[c] = ext[-@history_length..].dup
            end
            @peak[c] = peak if peak > @peak[c]
            @sumsq[c] += sumsq
            @true_peak = tp if tp > @true_peak

            if @weights[c] != 0
              shelf, highpass = @filters[c]
              x.inplace!
              shelf.process(x)
              highpass.process(x)
              x.not_inplace!
              @block_energy += FastLoudness.sum_squares(x) * @weights[c]
            end
            c += 1
          end
          @count += n

          @block_frames += n
          return if @block_frames < @block_length

          @energies << @block_energy
          @frames << @block_frames
          if @energies.length > BLOCKS
            @energies.shift
            @frames.shift
          end
          @block_energy = 0.0
          @block_frames = 0
        end

        # The readings since the last #take (MasterLevels), starting a new
        # interval.  Short-term loudness covers the last 3 s whatever the
        # interval.
        def take
          rms = @sumsq.map { |s| @count > 0 ? Math.sqrt(s / @count).to_db : -Float::INFINITY }
          frames = @frames.sum
          lufs = frames > 0 && @energies.sum > 0 ? Loudness.lufs(@energies.sum / [frames, @block_length * BLOCKS].max) : -Float::INFINITY
          levels = MasterLevels.new(
            peak: @peak.map { |p| p > 0 ? p.to_db : -Float::INFINITY }.freeze,
            rms: rms.freeze,
            true_peak: @true_peak > 0 ? @true_peak.to_db : -Float::INFINITY,
            lufs_s: lufs
          )
          reset_interval
          levels
        end

        class << self
          # False to use the Numo path (the exact mirror of
          # FastLoudness.meter_block) instead of the kernel.
          attr_accessor :native
        end
        self.native = true

        private

        # FastLoudness.meter_block for channel +c+ into its reused buffers
        # (results in @result); returns the widened samples.
        def native_block(c, buf, n)
          ext = @ext[c]
          if ext.nil? || ext.length != @history_length + n
            old = ext ? ext[0...@history_length] : @history[c]
            ext = @ext[c] = Numo::DFloat.zeros(@history_length + n)
            ext[0...@history_length] = old
            @x[c] = Numo::DFloat.zeros(n)
          end
          FastLoudness.meter_block(buf, ext, @x[c], @phases, @result)
          @x[c]
        end

        # The Numo path's history of channel +c+ (from the native path's
        # buffer if that ran last).
        def history_of(c)
          if (ext = @ext[c])
            @history[c] = ext[0...@history_length].dup
            @ext[c] = nil
          end
          @history[c]
        end

        def reset_interval
          @peak = Array.new(@channels, 0.0)
          @sumsq = Array.new(@channels, 0.0)
          @true_peak = 0.0
          @count = 0
        end
      end

      # The latest +length+ samples of each channel, kept in a ring on the
      # render thread.
      class ScopeRing
        attr_reader :length

        def initialize(channels, length)
          @length = length
          @rings = Array.new(channels) { Numo::SFloat.zeros(length) }
          @pos = 0
        end

        # Adds one buffer (an Array of Numo::SFloat).
        def write(mix)
          n = mix[0].length
          if n >= @length
            @rings.each_with_index { |r, c| r[0..] = (mix[c] || mix[0])[(n - @length)..] }
            @pos = 0
            return
          end

          first = MB::M.min(n, @length - @pos)
          c = 0
          while c < @rings.length
            r = @rings[c]
            m = mix[c] || mix[0]
            # (FastArithmetic.circular_write: the same copy without views)
            unless MB::Sound::FastArithmetic.circular_write(r, m, @pos)
              r[@pos...(@pos + first)] = m[0...first]
              r[0...(n - first)] = m[first...n] if first < n
            end
            c += 1
          end
          @pos = (@pos + n) % @length
        end

        # The samples oldest first (new frozen SFloats, one per channel).
        def to_a
          @rings.map { |r| (@pos == 0 ? r.dup : r[@pos..].concatenate(r[0...@pos])).freeze }.freeze
        end
      end

      # The render thread's side of the UI ("snapshots in"): attached to a
      # Session as its #ui_feed, it accumulates each buffer (load, and with
      # #needs, master meters and a scope ring) and, whenever the painter
      # has taken the last snapshot, publishes a new frozen Snapshot (one
      # reference swap; nothing waits).  So snapshots come at most once per
      # buffer and at most as often as the painter draws, and meters cover
      # every buffer in between (peaks are never missed).
      class Feed
        # Samples per channel kept for scope panes.
        SCOPE_LENGTH = 1024

        # What visible panes need besides the basics (:meters, :scope).
        attr_reader :needs

        # The Slow data and knobs (set by the painter's Poll) included in
        # every snapshot.
        attr_accessor :slow

        # Snapshots published so far.
        attr_reader :published

        def initialize(scope_length: SCOPE_LENGTH)
          @scope_length = scope_length
          @needs = [].freeze
          @slow = Slow.empty
          @knob_refs = [].freeze
          @taken = true
          @latest = nil
          @published = 0
          reset_interval
        end

        # Sets what panes need (Symbols; see #needs).
        def needs=(list)
          @needs = list.uniq.freeze
        end

        # Knobs to read into each snapshot: an Array of [name, knob]
        # (GraphNode::Knob), replaced by the painter's Poll.
        def knob_refs=(refs)
          @knob_refs = refs.freeze
        end

        # The render thread's BusMeter for +session+ while a pane needs
        # :buses (see Session::Buses#render_routed), else nil.
        def bus_meter(session)
          return @bus_meter = nil unless @needs.include?(:buses)
          ch = session.channels
          @bus_meter = nil if @bus_meter && @bus_meter.channels != ch
          @bus_meter ||= BusMeter.new(ch, session.sample_rate)
        end

        # True when the painter has taken the last snapshot (the Session
        # then calls #capture).
        def wants_capture?
          @taken
        end

        # The render thread, with the render lock held: reads the parts and
        # the transport record for the next snapshot.
        def capture(session)
          @parts = session.ui_parts
          @record = session.transport_record
        end

        # The render thread, after each buffer is written: accumulates it,
        # and publishes a snapshot if #capture ran.
        def publish(session, mix, count, load)
          @frames += count
          if load
            @load_sum += load * count
            @load_max = load if load > @load_max
          end

          if @needs.include?(:meters)
            @meter ||= MasterMeter.new(mix.length, session.sample_rate)
            @meter.process(mix)
          end
          if @needs.include?(:scope)
            @scope = nil if @scope && @scope.length != @scope_length
            @scope ||= ScopeRing.new(mix.length, @scope_length)
            @scope.write(mix)
          end

          return unless @parts && @record

          @latest = build(session)
          @published += 1
          @taken = false
          @parts = @record = nil
          reset_interval
        end

        # The newest snapshot, marked as taken (so the render thread makes
        # another after its next buffer); nil before the first.
        def take
          s = @latest
          @taken = true
          s
        end

        # The newest snapshot without taking it.
        def latest
          @latest
        end

        private

        def build(session)
          rate = session.sample_rate.to_f
          seconds = @frames / rate
          rec = @record
          stamp = Session::Stamp.at(rec[:pos], session.transport)
          parts = @parts.map { |p|
            PartLoad.new(name: p.name, kind: p.kind, state: p.state, load: seconds > 0 ? p.cpu / seconds : 0.0)
          }.freeze
          out = session.output
          underruns = out.respond_to?(:underruns) ? out.underruns : nil
          bus_levels, send_levels = @needs.include?(:buses) && @bus_meter ? @bus_meter.take : [nil, nil]

          Snapshot.new(
            seq: @published + 1, time: MB::U.clock_now, frame: rec[:frame], pos: rec[:pos],
            bar: stamp.bar, beat: stamp.beat, bpm: rec[:bpm], bar_length: rec[:bar_length], playing: rec[:playing],
            sample_rate: rate, buffer_size: session.buffer_size,
            load: @frames > 0 && @load_sum > 0 ? @load_sum / @frames : nil, load_max: @load_max > 0 ? @load_max : nil,
            parts: parts,
            master: @needs.include?(:meters) && @meter ? @meter.take : nil,
            scope: @needs.include?(:scope) && @scope ? @scope.to_a : nil,
            underruns: underruns,
            knobs: @knob_refs.map { |name, k| KnobValue.new(name: name, value: k.value, spec: k.spec) }.freeze,
            slow: @slow,
            latency: out.respond_to?(:latency) ? out.latency.to_f : 0.0,
            bus_levels: bus_levels, send_levels: send_levels,
            notes: session.respond_to?(:held_notes) ? session.held_notes : [].freeze,
            sounding: nil
          )
        end

        def reset_interval
          @frames = 0
          @load_sum = 0.0
          @load_max = 0.0
        end
      end
    end
  end
end
