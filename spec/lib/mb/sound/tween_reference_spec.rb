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
  # Re-recorded again 2026-10-11 for graph-io-1: each unison copy's block now
  # runs in MB::Sound.with_seed(seed + 1 + i) (maintainer decision 2026-10-10:
  # one seed rebuilds the whole unison/swarm; changed random phases accepted).
  # Verified: dropping only that with_seed wrap restores 82da65e6... and
  # 4cac9d2f...; with it, 101635532e470ae6 and 2f97ec1c69d19302.
  # Re-recorded 2026-10-13 for fixes-6: tones with a frequency signal keep a
  # running phase wrapped every sample (mb_phase.h); last bits only (max
  # difference -155 and -161 dB re peak, rms -192 and -198 dB).
  it 'keeps swarms unchanged' do
    expect(digest(mel.synth(voices: 1) { |v| v.hz.swarm(6, glide: MB::Sound.spread(40.ms..400.ms), overshoot: 0..0.1, seed: 3) }.mono)).to eq('245658de1a896ab9')
    expect(digest(mel.synth(voices: 1) { |v| v.hz.swarm(5, seed: 4) }.mono)).to eq('d92266a8028ae4a3')
  end

  # The smoothing digest was re-recorded 2026-10-30 for smoothing-1:
  # GraphNode#smooth became Notes::Smoother's B-spline FIR (a linear filter;
  # the old Filter::Smoothstep restarted a smoothstep on every change) and
  # starts on the input's first value instead of gliding up from 0.
  it 'keeps smoothing and envelopes unchanged' do
    expect(digest(mel.number.smooth(0.05))).to eq('e2a373f8875d6018')
    env = MB::Sound::Envelope.new(attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.3, curve: :analog, shape: [:s, :exp, :s], hold: 0.5, sample_rate: 48000)
    expect(digest(env, 40)).to eq('64a4e0b90eebadff')
    expect(digest(mel.amp_env(0.01, 0.1, 0.6, 0.2))).to eq('32ea2015ce640f56')
  end
end
