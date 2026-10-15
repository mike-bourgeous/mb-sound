# Fake snapshots for terminal UI specs (spec/lib/mb/sound/ui/): a set in
# its drop, with tracks, a queued change, knobs, master levels, and a scope,
# all fixed (no Session), so band text is deterministic.
module UIHelpers
  UI = MB::Sound::UI

  def ui_knob_spec(name, default, range, **opts)
    MB::Sound::GraphNode::Knob::Spec.new(name: name, default: default, range: range, **opts)
  end

  # The Slow part: tracks, scenes, queued changes, a recording, the form.
  def ui_fake_slow
    UI::Slow.new(
      tracks: [
        UI::TrackInfo.new(name: :drums, q: '1', clip: 'beat_a', armed: false),
        UI::TrackInfo.new(name: :bass, q: '1', clip: 'bass_a', armed: false),
        UI::TrackInfo.new(name: :lead, q: '1', clip: 'no clip', armed: true),
        UI::TrackInfo.new(name: :pad, q: '1', clip: 'chords', armed: false),
      ].freeze,
      scenes: %i[intro drop break].freeze,
      scene: :drop,
      queued: [
        UI::QueuedInfo.new(seq: 9, kind: :mute, subject: :pad, lands: '18:1', pos: 17r),
        UI::QueuedInfo.new(seq: 8, kind: :knob, subject: :cut, lands: '17:3', pos: 16.5r),
      ].freeze,
      recording: [UI::RecordingInfo.new(name: :lead, ends: '21:1', pos: 20r, queued: false)].freeze,
      armed: [:lead].freeze,
      form: UI::FormInfo.new(section: :drop, pass: 1, from: 12r, to: 20r, next: :break, next_at: '21:1', committed: true, looping: false, ended: false),
      knob_specs: {}.freeze
    )
  end

  # A full Snapshot at bar 17 beat 3 (+t+ seconds, +seq+), with a 440 Hz
  # scope of +scope_phase+.
  def ui_fake_snapshot(t: 1.0, seq: 1, scope_phase: 0.0, peak: -8.1)
    scope = [0.7, 0.35].map { |a|
      Numo::SFloat.new(1024).seq.map { |i| a * Math.sin(2 * Math::PI * (440.0 * i / 48000 + scope_phase)) }.freeze
    }.freeze
    UI::Snapshot.fake(
      seq: seq, time: t, frame: 1_536_000, pos: 16.5r, bar: 17, beat: 3r, bpm: 128, bar_length: 1r, playing: true,
      load: 0.31, load_max: 0.45,
      parts: [
        UI::PartLoad.new(name: :drums, kind: :player, state: :playing, load: 0.04),
        UI::PartLoad.new(name: :bass, kind: :player, state: :playing, load: 0.12),
        UI::PartLoad.new(name: :pad, kind: :player, state: :stopping, load: 0.02),
        UI::PartLoad.new(name: :verb, kind: :bus, state: :playing, load: 0.06),
        UI::PartLoad.new(name: :master, kind: :master, state: :playing, load: 0.03),
      ].freeze,
      master: UI::MasterLevels.new(peak: [peak, peak - 0.3].freeze, rms: [-18.0, -18.2].freeze, true_peak: -0.6, lufs_s: -14.2),
      scope: scope,
      underruns: 0,
      knobs: [
        UI::KnobValue.new(name: :cut, value: 2400.0, spec: ui_knob_spec(:cut, 800.0, 100.0..8000.0, curve: :exp, unit: 'Hz')),
        UI::KnobValue.new(name: :drive, value: 0.3, spec: ui_knob_spec(:drive, 0.0, 0.0..1.0)),
      ].freeze,
      slow: ui_fake_slow
    )
  end

  # A Band on a StringIO, +size+ [rows, cols], painting only on #refresh,
  # drawing ui_fake_snapshot (or the block's snapshot for each refresh).
  def ui_fake_band(layout = :band, size: [30, 120], native: true, at: :top, color: :ansi256, &snap)
    io = StringIO.new
    snap ||= -> { ui_fake_snapshot }
    band = UI::Band.new(layout: UI.layout_named(layout), io: io, size: size, native: native, at: at, color: color, clock: -> { 0.0 }, source: snap)
    [band, io]
  end
end

RSpec.configure do |c|
  c.include UIHelpers
end
