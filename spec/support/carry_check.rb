# The carry check (carry-1; research-snapshot-mutability's "carry check
# mode", like MB_SOUND_PLAN_CHECK for plans): a track's patch is played
# twice in non-realtime Sessions from the same seed, once uninterrupted
# and once with a carrying rebuild (what a bind or a build knob's turn
# does; Session::Carry), and the two mixes are compared window by window
# after the swap.  A swap that cuts (Carry::Plan#full?) must give the
# uninterrupted samples bit for bit; the windows say where it doesn't
# (the study's dnb_neuro, ambient_bowl, and ambient_rin holes showed
# 925 samples after their swaps once adoption made them cuts).
#
#   r = CarryCheck.compare(:dnb_pad, clip: CarryCheck::NOTES)
#   r.exact?      # => true
#   r.to_s        # "cut, bit for bit" or where the first window differs
#
# Used by carry_spec.rb, carry_sweep_spec.rb (every shipped preset), and
# SessionFuzz's :carry relation.
module CarryCheck
  # A held note across bar 2:1 (where rebuilds land at 120 BPM), then a
  # loop restart.
  NOTES = MB::Sound.seq(MB::Sound::C3.n2, MB::Sound::E3.n1).loop

  # Every GM drum note (any kit's voices).
  DRUMS = MB::Sound.seq(*(35..81).map { |k| MB::Sound::Note.new(k) }).n16.loop

  # The frame the rebuild lands on (bar 2:1 at 120 BPM).
  SWAP = 96_000

  # The frame the rebuild is asked for.
  ACT_AT = 3200

  # The rebuild a bind makes, without binding (+carry+ false: a fresh graph).
  REBUILD = ->(s, carry = true) {
    arr = s.arrangement
    tr = arr.tracks.values.first
    s.command('rebuild') { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil, carry: carry) }
  }

  # What .compare found: the uninterrupted and the carried mono mixes
  # (DFloat), the swap's Carry::Plan, and the residual per window after the
  # swap ([[first frame, dB below the uninterrupted window's peak], ...];
  # -Infinity where bit for bit).
  Result = Data.define(:plain, :carried, :plan, :windows, :window, :swap) do
    def exact? = plain == carried

    # True if the samples before the swap are the same (the rebuild didn't
    # change what played before it landed).
    def same_before? = plain[0...swap] == carried[0...swap]

    # The loudest window's residual in dB (-Infinity if bit for bit).
    def worst_db = windows.map(&:last).max || -Float::INFINITY

    # The first window differing by more than +db+ (below its peak), as
    # [frame, dB], or nil.
    def first_over(db = -Float::INFINITY) = windows.find { |_, d| d > db }

    def to_s
      kind = plan.nil? ? 'no carry' : (plan.full? ? 'cut' : 'crossfade')
      return "#{kind}, bit for bit" if exact?

      f, d = first_over
      "#{kind}, #{worst_db.round(1)} dB worst; first difference in the #{window}-frame window at frame #{f} " \
        "(#{f - swap} after the swap, #{d.round(1)} dB)#{" (#{plan})" if plan}"
    end
  end

  module_function

  # Plays +patch+ (a track patch block, or an instrument name) from +clip+
  # uninterrupted and with +act+ (default: a carrying rebuild) after
  # ACT_AT frames, in +size+-frame buffers for +frames+ frames, and
  # compares them per +window+ frames after the swap.  Returns a Result.
  # +bpm+ sets the tempo (the swap lands on the floor sample of bar 2:1).
  def compare(patch, clip: NOTES, act: REBUILD, size: 800, frames: 160_000, window: 2400, bpm: nil)
    plain, = play(patch, clip: clip, size: size, frames: frames, bpm: bpm)
    carried, plan = play(patch, clip: clip, act: act, size: size, frames: frames, bpm: bpm)
    swap = bpm ? (4 * 60 * 48_000 / bpm.to_r).floor : SWAP
    Result.new(plain: plain, carried: carried, plan: plan, windows: windows(plain, carried, window: window, from: swap), window: window, swap: swap)
  end

  # The mono mix of a track playing +patch+ from +clip+ (see .compare),
  # with +act+ run in the Session's context after ACT_AT frames.  Returns
  # [samples, Session#last_carry, Session#spills].
  def play(patch, clip: NOTES, act: nil, size: 800, frames: 160_000, bpm: nil)
    old_bpm = MB::Sound.bpm if bpm
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: size)
    s = MB::Sound::Session.new(output: out, realtime: false, buffer_size: size)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.bpm(bpm) if bpm
      patch.is_a?(Symbol) ? MB::Sound.track(:lead, patch) : MB::Sound.track(:lead, &patch)
      MB::Sound.bg(:lead, clip)
    end
    s.process_buffer while s.frame < ACT_AT
    MB::Sound::Session.with_context(session: s) { act.call(s) } if act
    s.process_buffer while s.frame < frames
    [Numo::DFloat.cast(out.captured[0])[0...frames], s.last_carry, s.spills]
  ensure
    s&.close
    MB::Sound.bpm(old_bpm) if old_bpm
    MB::Sound.rewind
  end

  # The residual of +got+ against +ref+ per +window+ frames from +from+
  # ([[frame, dB below ref's peak in that window (or the overall peak if
  # the window is silent)], ...]).
  def windows(ref, got, window: 2400, from: SWAP)
    n = [ref.length, got.length].min
    peak = [ref[from...n].abs.max, 1e-12].max
    (from...n).step(window).map { |f|
      e = [f + window, n].min
      d = (got[f...e] - ref[f...e]).abs.max
      p = [ref[f...e].abs.max, peak * 1e-3].max
      [f, d == 0 ? -Float::INFINITY : 20 * Math.log10(d / p)]
    }
  end

  # Records the Carry::Plans applied while the block runs (on any
  # thread); returns them.
  def recording
    Recorder.install
    Recorder.start
    yield
    Recorder.plans
  ensure
    Recorder.stop
  end

  # For SessionFuzz's :carry relation (a line of a generated song, run in a
  # scheduled block): the carrying rebuild a bind makes, of track +name+ of
  # the current Session, if it plays a patch; else nothing.
  def fuzz_rebuild(name)
    s = MB::Sound::Session.current
    arr = s.arrangement
    tr = arr.tracks[name]
    return unless fuzz_rebuildable?(s, name, tr)

    s.command("rebuild #{name}") { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil, carry: true) }
    nil
  end

  # The twin of .fuzz_rebuild for the render without rebuilds: a change
  # that does nothing, splitting the buffer where the rebuild would land,
  # as a carrying swap does (so the two renders differ only by the
  # rebuild: a split alone moves a sidechain's duck by a sample).
  def fuzz_split(name)
    s = MB::Sound::Session.current
    arr = s.arrangement
    tr = arr.tracks[name]
    return unless fuzz_rebuildable?(s, name, tr)

    time = arr.send(:early, tr, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE))
    s.instance_variable_get(:@render_lock).synchronize { s.send(:change, :skip, name, time, split: true) { |_| } }
    nil
  end

  # True if track +tr+ (+name+) of Session +s+ plays a graph of
  # its patch with no start of another queued to land by the rebuild's
  # landing (such a rebuild is dropped, or replaces the launched graph
  # without carrying: not what the relation checks).
  def fuzz_rebuildable?(s, name, tr)
    return false unless tr&.patch?

    arr = s.arrangement
    time = arr.send(:early, tr, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE))
    started = s.instance_variable_get(:@mutex).synchronize { s.instance_variable_get(:@players).each_value.any? { |p| p.name == name && p.current? } }
    queued = s.instance_variable_get(:@render_lock).synchronize {
      s.instance_variable_get(:@changes).any? { |c| c.subject == name && MB::Sound::Session::START_KINDS.include?(c.kind) && c.time <= time }
    }
    started && !queued
  end

  # Prepended once to Session::Carry's singleton: notes each applied plan
  # while recording.
  module Recorder
    @mutex = Mutex.new
    @plans = nil

    class << self
      def install
        MB::Sound::Session::Carry.singleton_class.prepend(Hook) unless MB::Sound::Session::Carry.singleton_class.include?(Hook)
      end

      def start = @mutex.synchronize { @plans = [] }
      def stop = @mutex.synchronize { @plans = nil }
      def plans = @mutex.synchronize { @plans.dup }
      def note(plan) = @mutex.synchronize { @plans&.push(plan) }
    end

    module Hook
      def apply(plan, **options)
        Recorder.note(plan)
        super
      end
    end
  end

  # True if instrument +name+ is a drum kit (it takes a Kit, not notes).
  def drums?(name)
    MB::Sound.keeping_random_state { MB::Sound.preset(name, midi: NOTES) }
    false
  rescue MB::Sound::GraphIO::LoadError => e
    raise unless e.message.include?('SourceMismatch')

    true
  end
end
