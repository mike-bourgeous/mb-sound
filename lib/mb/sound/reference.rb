module MB
  module Sound
    # A/B against a reference sound while tuning (hand-tune-1, 2026-11-03;
    # research-voice-match-3's hand-tune loop: "the reference on a second
    # track muted, with a one-key A/B").  `ab :kick, 'kick_ref.wav'` puts
    # the reference on its own track (:kick_ref) playing the patch track's
    # clip through a one-voice sampler at the sample's own pitch, so every
    # note of the clip plays the reference from its start, muted, with its
    # level set so its loudness matches the patch's; `ab` (or `ab :kick`,
    # or b in the inspector) flips which of the two is heard: one undo
    # step that mutes one and unmutes the other, journaled and in the take,
    # so a take reader sees when he listened to which.
    #
    # Loudness: integrated LUFS (BS.1770, gated) of one note of the patch,
    # rendered offline from its graph document at the track's knob values
    # now, against the reference's first seconds (the same length, at most
    # MATCH_SECONDS).  Measured again on a flip to the reference when the
    # knobs moved since, so the reference stays matched while he tunes.
    # Patches that aren't graph documents (patch blocks) can't be rendered
    # offline at their knobs: the reference plays at unity and the pair
    # says so.
    #
    # The reference's file is read when `ab` sets it up (through ffmpeg
    # like any sound file; a Sample can be given instead); flips start no
    # processes.
    module Reference
      # The longest stretch of both sounds the loudness match measures.
      MATCH_SECONDS = 4.0

      # The shortest (a short one-shot measures as one 400 ms block).
      MIN_SECONDS = 0.1

      # One track's A/B: +track+ (the patch's track), +ref+ (the
      # reference's track), +sample+, +source+ (what was given: a path or
      # the Sample's name), +hearing+ (:patch or :ref), +level_db+ (the
      # reference's level now, dB), +patch_lufs+ and +ref_lufs+ (the last
      # match; nil when not measured), +values+ (the knob values of the
      # last match), +note+ (why it isn't matched, or nil), +alt+ (a third
      # track in the A/B: refine's proposal, :"<track>_refined", or nil;
      # flips then cycle patch -> alt -> reference: hearing :alt).
      Pair = Struct.new(:track, :ref, :sample, :source, :hearing, :level_db, :patch_lufs, :ref_lufs, :values, :note, :alt, keyword_init: true) do
        def to_s
          match = patch_lufs && ref_lufs ? "patch #{fmt(patch_lufs)} LUFS, reference #{fmt(ref_lufs)} LUFS, reference level #{fmt(level_db)} dB" : (note || 'not matched')
          heard = case hearing
                  when :ref then "reference (#{ref.inspect})"
                  when :alt then "refined (#{alt.inspect})"
                  else "patch (#{track.inspect})"
                  end
          "ab #{track.inspect}: hearing the #{heard}; #{match}"
        end

        # The tracks the flips cycle through, in order.
        def cycle = alt ? [track, alt, ref] : [track, ref]

        # What #hearing names each track of #cycle.
        def hearings = alt ? %i[patch alt ref] : %i[patch ref]

        def inspect = "#<#{self}>"

        private def fmt(x) = format('%+.1f', x).sub('+-', '-')
      end

      class << self
        # The pairs of +session+ ({ track => Pair }).
        def pairs(session = Session.current)
          (@pairs ||= ObjectSpace::WeakKeyMap.new)[session] ||= {}
        end

        # The pair of +track+ in +session+, or the one pair, or the last
        # one set up (nil: none).
        def pair(session, track = nil)
          list = pairs(session)
          return list[track] if track
          @last && list[@last] ? list[@last] : list.values.last
        end

        # Sets up +track+'s reference +sound+ (a file path or a Sample) on
        # track +as+ (default :"<track>_ref"), muted, its level matched
        # (see the module description).  Returns the Pair.
        def setup(session, track, sound, as: nil)
          arr = session.arrangement
          tr = arr.tracks[track] or raise ArgumentError, "ab: no track #{track.inspect} (#{arr.tracks.keys.map(&:inspect).join(', ')}): make it first (design :#{track}, fit)"
          sample = sound.is_a?(Sample) ? sound : Sample[sound.to_s]
          ref = as || :"#{track}_ref"
          inst = sample.to_instrument(keytrack: 0)
          pair = Pair.new(track: track, ref: ref, sample: sample, source: sound.is_a?(Sample) ? (sample.name || 'a Sample') : sound.to_s,
                          hearing: :patch, level_db: 0.0)
          Session.with_context(session: session) do
            session.command("ab #{track.inspect}") do
              MB::Sound.track(ref) { |clip| MB::Sound.sampler(clip, inst) }
              MB::Sound.mute(ref)
              clip = tr.clip
              MB::Sound.bg(ref, clip) if clip
            end
          end
          pairs(session)[track] = pair
          @last = track
          match(session, pair)
          pair
        end

        # Flips +track+'s pair (the last one set up when nil) between the
        # patch and the reference (through refine's proposal first when the
        # pair has one: Pair#alt), matching the reference's level again
        # first when the patch's knobs moved.  +to+ picks what to hear
        # (:patch, :alt, :ref) instead of the next.  Returns the Pair.
        def flip(session, track = nil, to: nil)
          pair = pair(session, track) or raise ArgumentError, "ab: no reference set up (ab #{(track || :kick).inspect}, 'reference.wav')"
          hearings = pair.hearings
          to ||= hearings[(hearings.index(pair.hearing).to_i + 1) % hearings.length]
          raise ArgumentError, "ab: hear one of #{hearings.map(&:inspect).join(', ')} (got #{to.inspect})" unless hearings.include?(to)
          match(session, pair) if to == :ref && pair.values != knob_values(session, pair.track)
          heard = pair.cycle[hearings.index(to)]
          Session.with_context(session: session) do
            session.command("ab #{pair.track.inspect}") do
              pair.cycle.each { |t| MB::Sound.mute(t) unless t == heard }
              MB::Sound.unmute(heard)
            end
          end
          pair.hearing = to
          @last = pair.track
          pair
        end

        # Stops +track+'s reference (its track stops; the patch is heard).
        def off(session, track = nil)
          pair = pair(session, track) or return nil
          Session.with_context(session: session) do
            session.command("ab #{pair.track.inspect}, :off") do
              MB::Sound.stop(pair.ref)
              MB::Sound.stop(pair.alt) if pair.alt
              MB::Sound.unmute(pair.track)
            end
          end
          pair.alt = nil
          pairs(session).delete(pair.track)
          @last = nil if @last == pair.track
          pair.hearing = :patch
          pair
        end

        # Matches +pair+'s reference level to its patch (see the module
        # description), setting the reference track's level.  Returns the
        # pair.
        def match(session, pair)
          values = knob_values(session, pair.track)
          seconds = pair.sample.seconds.to_f.clamp(MIN_SECONDS, MATCH_SECONDS)
          audio = patch_audio(session, pair.track, seconds, values: values)
          unless audio
            pair.note = "not loudness-matched: #{pair.track.inspect}'s patch isn't a graph document (a fit_patch or a preset), so it can't be rendered at its knobs offline"
            pair.values = values
            return pair
          end
          pl = lufs(audio, 48000)
          rl = lufs(pair.sample.to_a.map { |c| c[0...(seconds * pair.sample.sample_rate).round] }, pair.sample.sample_rate)
          pair.patch_lufs = pl
          pair.ref_lufs = rl
          pair.values = values
          if pl.finite? && rl.finite?
            pair.level_db = (pl - rl).clamp(-60.0, 12.0)
            pair.note = nil
            Session.with_context(session: session) { MB::Sound.level(pair.ref, Decibels.new(pair.level_db)) }
          else
            pair.note = "not loudness-matched: #{pl.finite? ? 'the reference' : 'the patch'} is silent over its first #{seconds.round(2)} s"
          end
          pair
        end

        # { param => value } of +track+'s graph document's params at the
        # track's knobs now (each param's knob, :"track/param"), or {} for
        # a patch that isn't a document.
        def knob_values(session, track)
          doc = document_of(session, track) or return {}
          doc.params.keys.to_h { |p|
            k = session.knobs[Session::Name.param(track, p)]
            [p, k ? k.value : doc.declarations[p].default]
          }
        end

        # The graph document +track+'s patch plays (GraphIO::Document, from
        # its library entry), or nil.
        def document_of(session, track)
          path = document_path(session, track) or return nil
          GraphIO.parse(path)
        end

        # The path of the graph document +track+'s patch plays, or nil.
        def document_path(session, track)
          tr = session.arrangement.tracks[track] or return nil
          e = tr.patch && Arrangement::InstrumentPatch.entry_of(tr.patch)
          return nil unless e && e.family == :preset && e.settings.is_a?(Hash) && e.settings[:document]
          e.location
        end

        # One note of +track+'s patch rendered offline for +seconds+ (an
        # Array of SFloats at 48 kHz) from its graph document with
        # +values+ ({ param => value }; default: the knobs now), the note
        # the track's clip plays first (else its role's), or nil when the
        # patch isn't a document.
        def patch_audio(session, track, seconds, values: nil)
          path = document_path(session, track) or return nil
          values ||= knob_values(session, track)
          note = note_of(session, track)
          HandTune.render(path, values, note: note[0], velocity: note[1], hold: note[2], seconds: seconds)
        end

        # [number, velocity, hold seconds or nil] of the first note
        # +track+'s clip plays, else its role's (UI::PatchRender.input, as
        # the render pane plays).
        def note_of(session, track)
          tr = session.arrangement.tracks[track]
          src = UI::PatchRender::Source.new(track: track, clip: tr&.clip, bpm: session.transport.bpm.to_f, bar_length: nil, key: nil, tuning: nil,
                                            channels: 1, note: nil, words: track.to_s)
          i = UI::PatchRender.input(src, MATCH_SECONDS)
          [i.note, i.velocity, i.hold]
        end

        # The integrated loudness of +channels+ at +rate+ (LUFS; -Infinity
        # for silence).
        def lufs(channels, rate)
          r = MB::Sound.loudness(channels.map { |c| Numo::SFloat.cast(c) }, sample_rate: rate, true_peak: false)
          v = r.integrated
          v.nil? ? -Float::INFINITY : v.to_f
        end
      end
    end

    # The console's ab (MB::Sound extends it; hand-tune-1).
    module ReferenceMethods
      # A/B against a reference while tuning (see Reference): `ab :kick,
      # 'kick_ref.wav'` puts the reference on track :kick_ref, playing
      # :kick's clip at the sample's own pitch, muted, loudness-matched to
      # the patch; `ab` (or `ab :kick`, or b in the inspector) flips what
      # you hear between the patch and the reference (matching again if
      # the knobs moved); `ab :kick, :off` stops the reference.  Returns
      # the Reference::Pair (it prints which one plays and the match).
      #
      #     design :kick, kick_fit, seq(C2).n4.loop
      #     ab :kick, 'tmp/samples/kick.wav'
      #     ab        # the reference
      #     ab        # the patch again
      def ab(track = nil, sound = nil, as: nil)
        s = Session.current
        return Reference.off(s) if track == :off
        return Reference.off(s, track) if sound == :off
        return Reference.setup(s, track, sound, as: as) if sound
        Reference.flip(s, track)
      end
    end

    extend ReferenceMethods
  end
end
