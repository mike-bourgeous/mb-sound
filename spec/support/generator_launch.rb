# Launching L.gen entries the way the console does, counting note-ons per
# bar (beat-halftime-1): `include GeneratorLaunch` in an example group, then
# `launch('bg :x, L.gen.beat.rock', bpm: 960, bars: 40)`, or
# `expect_keeps_playing(entry)` for the family sweep (every entry still
# playing well past its cycles, fills, and the 8-bar audition).
module GeneratorLaunch
  def self.included(group)
    group.before {
      @sessions = []
      @notes = nil
      # (note-ons as the clip sources send them, while a launch is recorded)
      allow_any_instance_of(MB::Sound::MIDI::ClipSource).to receive(:edges).and_wrap_original { |m, *args|
        m.call(*args).tap { |out| out.each { |e| @notes << e.time if @notes && e.respond_to?(:type) && e.type == :note_on } }
      }
    }
    group.after {
      @sessions.each(&:close)
      MB::Sound.rewind
      MB::Sound.bpm(120)
    }
  end

  # Runs console +code+ (a String evaluated in MB::Sound, as typed) in a
  # new non-realtime Session at +bpm+ for +bars+ bars, with the :x track
  # knob for energy, density, or chance under a 2-bar square if +steer+;
  # returns [note-ons per bar, the players at the end, the session].
  def launch(code, bpm:, bars:, steer: false, buffer: 4800)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: buffer, sleep: false), realtime: false)
    @sessions << s
    @notes = []
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.rewind
      MB::Sound.seed(1)
      MB::Sound.bpm(bpm)
      MB::Sound.instance_eval(code.gsub(/\bL\./, 'MB::Sound::L.'))
      if steer
        k = s.knobs.keys.find { |n| n.to_s.match?(%r{\Ax/(energy|density|chance)\z}) }
        MB::Sound.turn(k, 2.bars.lfo.square.at(0.2..1)) if k
      end
    end
    bar = 240r / bpm
    (bars * bar * s.sample_rate / buffer).ceil.times { s.process_buffer }
    per = Array.new(bars, 0)
    @notes.each { |t| b = (t / bar + 1e-9).floor; per[b] += 1 if b < bars }
    @notes = nil
    [per, s.players.keys, s]
  end

  # The windows of +per+ (note-ons per bar) that must have notes: from
  # bar 9 (past the 8-bar audition), from bar 33, and the last, each as
  # long as the entry's cycle and at least 8 bars (sparse entries have
  # empty bars: ambient_roots plays once per 8-bar cycle).  { first bar
  # (1-based) => notes }.
  def late_windows(entry, per)
    w = [entry.call.length.ceil, 8].max
    [9, 33, per.length - w + 1].select { |b| b >= 9 && b + w - 1 <= per.length }.uniq.to_h { |b| [b, per[b - 1, w].sum] }
  end

  # The family sweep's checks for +entry+ (call from an example in the
  # spec file, so file times count there).  +tier+ :everyday: on a track
  # and with no track, at a fast tempo (the property is in bars: 40 at 960
  # BPM), plain.  :slow (the *_slow_spec.rb files, tagged :slow; fixes-17
  # moved them out so the everyday files keep tight time budgets): a
  # steered run, 85 and 170 BPM, bar 65, and the beats on their kit's
  # track (also at 960 BPM).  Drum beats also play every bar, bars 33-40
  # about as busy as bars 1-8.
  def expect_keeps_playing(entry, tier: :everyday)
    # [BPM, steered, bars]
    configs = tier == :slow ? [[960, false, 40], [960, true, 65], [85, false, 65], [170, true, 65]] : [[960, false, 40]]
    configs.each do |bpm, steer, bars|
      spellings = { track: "track :x, #{entry.head_path}; bg :x", no_track: "bg :x, #{entry.head_path}" }
      spellings[:kit] = "track :x, #{entry.settings[:instrument].inspect}; bg :x, #{entry.head_path}" if entry.family == :beat && tier == :slow
      # (the everyday run's spellings aren't repeated in the slow tier)
      spellings = spellings.slice(:kit) if tier == :slow && bpm == 960 && !steer
      spellings.each do |label, code|
        next if steer && label == :no_track
        per, players, = launch(code, bpm: bpm, bars: bars, steer: steer)
        what = "#{entry.head_path} #{label} at #{bpm} BPM#{' steered' if steer}: #{per.inspect}"
        expect(players).to eq([:x]), what
        late_windows(entry, per).each { |b, n| expect(n).to be > 0, "#{what}: silent from bar #{b}" }
        next unless entry.family == :beat

        expect(per.min).to be > 0, what
        ratio = per[32, 8].sum.to_f / per[0, 8].sum
        expect(ratio).to be_between(0.6, 1.6), "#{what}: bars 33-40 against 1-8"
      end
    end
  end
end
