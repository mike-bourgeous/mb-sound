require 'digest'

# Outputs of existing glides, swarms, smoothing, and envelopes, recorded on
# master-ai before the tweening work (2026-10-07), so the curve library and
# shape options leave the defaults bit-identical.
RSpec.describe('Tweening reference outputs') do
  def digest(node, n = 300)
    bufs = n.times.map { node.sample(480).dup }
    Digest::SHA256.hexdigest(Numo::SFloat.cast(bufs.reduce { |a, b| a.concatenate(b) }).to_binary)[0, 16]
  end

  let(:mel) { MB::Sound.seq(MB::Sound::A3, MB::Sound::C4.n8, MB::Sound::E4.n8, MB::Sound::D4, MB::Sound::G3).n4.legato(0.95).loop }

  before { MB::Sound.seed(1) }
  after { MB::Sound.rewind }

  it 'keeps glides unchanged' do
    expect(digest(mel.notes.hz.glide(150.ms).freq)).to eq('af9ea94f38a55686')
    expect(digest(mel.notes.hz.glide(150.ms, overshoot: 0.2).freq)).to eq('14db6cb23237889d')
    expect(digest(mel.notes.hz.glide(100.ms, from: 440.hz).freq)).to eq('81530cceaf3dd9dc')
  end

  # Swarm digests re-recorded 2026-10-08 after merging tweening onto master-ai:
  # the followups merge (caa39a5e) deliberately changed key-synced note starts
  # (reset step correction) and the node-detune default, which swarms use
  # (verified: 260b50aa... before caa39a5e, 82da65e6... after, unchanged by tweening).
  it 'keeps swarms unchanged' do
    expect(digest(mel.synth(voices: 1) { |v| v.hz.swarm(6, glide: MB::Sound.spread(40.ms..400.ms), overshoot: 0..0.1, seed: 3) }.mono)).to eq('82da65e65a627760')
    expect(digest(mel.synth(voices: 1) { |v| v.hz.swarm(5, seed: 4) }.mono)).to eq('4cac9d2fac201fa3')
  end

  it 'keeps smoothing and envelopes unchanged' do
    expect(digest(mel.number.smooth(0.05))).to eq('b44a742c3afe127f')
    env = MB::Sound::Envelope.new(attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.3, curve: :analog, shape: [:s, :exp, :s], hold: 0.5, sample_rate: 48000)
    expect(digest(env, 40)).to eq('64a4e0b90eebadff')
    expect(digest(mel.amp_env(0.01, 0.1, 0.6, 0.2))).to eq('32ea2015ce640f56')
  end
end
