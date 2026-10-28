require 'midilib'

# A small Standard MIDI File writer for specs (midi-import-1): builds files
# with midilib from plain Arrays, so specs and demos never need private
# MIDI.  Times are ticks.
#
#     MidiWriter.write(path, ppqn: 960, tempos: [[0, 180]], meters: [[0, 4, 4]],
#       tracks: [{ name: 'Bass', channel: 0, notes: [[0, 960, 36, 100]], cc: [[0, 1, 64]] }])
#
# +tempos+ are [tick, BPM] (nil or [] writes no tempo event); +meters+
# [tick, numerator, denominator].  Tempos and meters go in a conductor
# track first unless +conductor: false+ (then in the first track).  Track
# Hashes: +name+ (nil writes no name: midilib reads "Unnamed"), +channel+
# (0-based), +notes+ [[on, off, note, velocity, channel]] (channel
# optional), +cc+ [[tick, controller, value]], +bend+ [[tick, 0..16383]],
# +pressure+ [[tick, value]], +program+.
#
# The fixtures below reproduce features of real files (the maintainer's
# survey, 2026-10-28) with made-up music.
module MidiWriter
  module_function

  def write(path, tracks:, ppqn: 960, tempos: [[0, 120]], meters: [], conductor: true)
    seq = MIDI::Sequence.new
    seq.ppqn = ppqn
    meta = []
    (tempos || []).each { |t, bpm| meta << at(MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(bpm).round), t) }
    meters.each { |t, n, d| meta << at(MIDI::TimeSig.new(n, Math.log2(d).round, 24, 8), t) }
    if conductor
      c = MIDI::Track.new(seq)
      c.name = 'Conductor'
      c.events.concat(meta)
      seq.tracks << c
      meta = []
    end

    tracks.each do |spec|
      t = MIDI::Track.new(seq)
      t.name = spec[:name] if spec[:name]
      t.events.concat(meta)
      meta = []
      ch = spec[:channel] || 0
      t.events << at(MIDI::ProgramChange.new(ch, spec[:program], 0), 0) if spec[:program]
      (spec[:notes] || []).each do |on, off, note, vel, nch|
        t.events << at(MIDI::NoteOn.new(nch || ch, note, vel || 100, 0), on)
        t.events << at(MIDI::NoteOff.new(nch || ch, note, 64, 0), off)
      end
      (spec[:cc] || []).each { |tick, n, v| t.events << at(MIDI::Controller.new(ch, n, v, 0), tick) }
      (spec[:bend] || []).each { |tick, v| t.events << at(MIDI::PitchBend.new(ch, v, 0), tick) }
      (spec[:pressure] || []).each { |tick, v| t.events << at(MIDI::ChannelPressure.new(ch, v, 0), tick) }
      seq.tracks << t
    end

    seq.tracks.each do |t|
      t.sort
      t.recalc_delta_from_times
    end
    File.open(path, 'wb') { |f| seq.write(f) }
    path
  end

  def at(event, tick)
    event.time_from_start = tick
    event
  end

  # A 180 BPM reese line like a bass from a legato mono synth: 4 bars of
  # 4/4 at 960 ppqn, notes that overlap the next one by 30 ticks (legato
  # playing), a CC 1 lane on a 32nd-note grid (120 ticks) that holds, ramps
  # up one 7-bit step at a time, jumps, and falls, a second track also
  # without a name (two "Unnamed" tracks), and a polyphonic pad of chords.
  # Returns the path.
  def reese_song(path, tempo: true)
    q = 960
    bar = 4 * q
    roots = [36, 36, 39, 41, 34, 36, 43, 41]
    notes = roots.each_with_index.map { |n, i| [i * 2 * q, (i + 1) * 2 * q + 30, n, 90 + i] }
    notes[-1][1] = 8 * 2 * q - 10 # (the last note ends before the loop's end)
    cc = [[0, 1, 0]]
    # bar 2: a ramp 0 -> 40 one step per 32nd, a hold, a jump to 120, a fall
    (0...40).each { |k| cc << [bar + k * 120, 1, k + 1] }
    cc << [2 * bar + 1200, 1, 120]
    (0...24).each { |k| cc << [3 * bar + k * 120, 1, 120 - (k + 1) * 4] }
    cc << [3 * bar, 7, 100]
    chords = [[60, 63, 67], [58, 62, 65]].each_with_index.flat_map { |ch, i| ch.map { |n| [i * 2 * bar, (i + 1) * 2 * bar, n, 70] } }
    write(path, ppqn: q, tempos: tempo ? [[0, 180]] : nil, meters: [[0, 4, 4]], tracks: [
      { channel: 0, notes: notes, cc: cc, program: 38 },
      { channel: 0, cc: [[0, 7, 90]] },
      { name: "Pad\x00", channel: 2, notes: chords, bend: [[bar, 8192 + 4000], [bar + 480, 8192]], pressure: [[2 * bar, 64]] },
    ])
  end

  # A one-track phrase without a tempo event (an exported loop): 3 bars
  # of quarter notes and a final half note, ending mid-bar 4 at 960 ppqn.
  def no_tempo_phrase(path)
    q = 960
    notes = (0...13).map { |i| [i * q, (i + 1) * q, 48 + (i % 5), 100] } + [[13 * q, 15 * q, 55, 80]]
    write(path, ppqn: q, tempos: nil, conductor: false, tracks: [{ notes: notes }])
  end

  # Rubato: 2 bars of quarter notes at 960 ppqn under a tempo map that
  # changes every beat (100, 80, 60, 120, ... BPM).
  def rubato(path)
    q = 960
    bpms = [100, 80, 60, 120, 90, 72, 140, 100]
    write(path, ppqn: q, tempos: bpms.each_with_index.map { |b, i| [i * q, b] }, meters: [[0, 4, 4]],
          tracks: [{ name: 'Piano', notes: (0...8).map { |i| [i * q, (i + 1) * q - 60, 60 + i, 90] } }])
  end

  # Drums in 6/8 (a 9/8 bar, then 6/8 again): GM drums on channel 10
  # split into kick, snare, and hat tracks (eighths are 480 ticks at 960
  # ppqn), plus a rolling bass on channel 1.  Bars: 6/8, 6/8, 9/8, 6/8.
  def drums_68(path)
    e = 480
    bars = [6, 6, 9, 6]
    starts = bars.each_with_index.map { |_b, i| bars[0...i].sum * e }
    kick = []
    snare = []
    hat = []
    starts.each_with_index do |s, i|
      kick << [s, s + 60, 36, 120] << [s + 3 * e, s + 3 * e + 60, 36, 100]
      snare << [s + 3 * e, s + 3 * e + 60, 38, 110]
      bars[i].times { |k| hat << [s + k * e, s + k * e + 30, 42, k.even? ? 90 : 60] }
    end
    hat << [starts[3] + 5 * e, starts[3] + 6 * e, 46, 100] # an open hat
    bass = starts.flat_map { |s| (0...6).map { |k| [s + k * e, s + (k + 1) * e - 20, k.even? ? 31 : 43, 90] } }
    write(path, ppqn: 960, tempos: [[0, 103]], meters: [[0, 6, 8], [starts[2], 9, 8], [starts[3], 6, 8]], tracks: [
      { name: 'Rolling Bass', channel: 0, notes: bass, cc: [[0, 7, 100]] },
      { name: 'hat 1', channel: 9, notes: hat },
      { name: 'snare', channel: 9, notes: snare },
      { name: 'kick1', channel: 9, notes: kick },
    ])
  end
end
