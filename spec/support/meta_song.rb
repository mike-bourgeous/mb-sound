# The song of the metadata specs (source-meta-1; meta_methods_spec.rb,
# graph_io_meta_spec.rb), written in MB::Sound so note names resolve as in
# the console.
module MB::Sound
  module MetaSong
    def self.const_missing(name)
      MB::Sound.const_get(name)
    end

    TRACK = { format: :acd, kind: :track, at: 0x12340, bytes: 5678, name: "the track's own name", fields: { color: 3, height: 80 } }.freeze
    BUS = { format: :acd, kind: :bus, id: 2, fields: { 'plug-in' => ['Reverb', 'Big Hall', 4096] } }.freeze
    SET = { format: :acd, file: 'project.acd', bytes: 1_234_567, version: '7.0', unread: 0.19 }.freeze

    # A small song: a patch track with two scenes, a graph track, a bus
    # with a send, and changes landing mid-song.  With +carried+, the same
    # song with metadata given before, between, and after its pieces, on a
    # node inside the patch, and from scheduled blocks while it plays.
    def self.song(carried)
      MB::Sound.instance_exec do
        seed 7
        bpm 120
        meta source: SET if carried
        meta :a3, source: TRACK if carried # (before the track exists)
        riff = seq(A2, C3, E3, G3).n8.loop.named(:riff)
        riff_b = riff.transpose(5).named(:riff_b)
        track(:a3, q: 1) { |clip|
          v = clip.synth(voices: 2) { |n| n.hz.saw.lp4(900, resonance: 0.3) * n.amp_env(0.003, 0.1, 0.5, 0.05) }
          v = v.with_meta(source: { format: :acd, kind: :plugin, id: 1 }) if carried
          v * 0.3 + noise.at(-40.db)
        }
        track :pad, 220.hz.triangle.at(-24.db)
        bus(:fx1) { |sig| sig.delay(1.n8, feedback: 0.3) }
        feed :a3, :fx1, -12.db
        meta :fx1, source: BUS if carried
        scene :one, a3: riff, pad: :on
        scene :two, a3: riff_b
        go :one, on: :now
        at_bar(2) { go :two }
        at_bar(2, beat: 3) { meta :a3, notes: 'mid-song'; meta :pad, source: { kind: :track, at: 99 } } if carried
        at_bar(3) { swap :a3, riff, on: :now }
        at_bar(3, beat: 2) { meta :ghost, source: { kind: :track, unread: 12 }; meta :a3, nil; meta :a3, source: TRACK } if carried
      end
    end
  end
end
