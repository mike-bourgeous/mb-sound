# Help topics for textures and short recipes (`help :textures`,
# `help :recipes`; textures-1, 2026-10-14).  Same rules as topics.rb: the
# guard spec plays every example and checks its level.
module MB
  module Sound
    Help.topic :textures, 'Textures: dust, drift, resonators', group: :sound do
      about <<~TEXT
        Small random things that make sounds feel alive.  `dust(rate)` is
        sparse random impulses (random heights, so as triggers they strike
        at random velocities; `bipolar: true` for crackle).  `drift(rate)`
        is a slow random line for detune, cutoffs, and pans (`smooth:`
        :cubic, :cosine, :linear, :step; `walk:` keeps each step small).
        Noise colors: `noise` is white; filter it for pink-ish
        (`noise.lp4(1200)`), dark wind (`.filter(:bandpass, ...)`), or hiss
        (`.filter(:highpass, ...)`).

        Struck objects: `trig.ping(f, decay:)` rings one sine;
        `trig.resonate(:bowl, f)` rings a whole object (:bowl, :rin, :gong,
        :bell, :chime, :bar, :marimba, :vibes, :glass, :plate, :membrane, or
        your own [[ratio, amp, decay share], ...]); `spread:` makes it
        stereo, `v.freq` in a synth makes it follow the keys.  Strike with
        dust, triggers, or a quiet noise (a rubbed rim).  Lowpass the strike
        for a softer mallet.  Everything is seeded (`seed 42`).

        Freezing: `reverb(:hall, freeze: ...)` holds a reverb's tail
        forever; granular freezes come with the sampler's grains.
      TEXT
      commands :dust, :drift, :noise
      dsl :resonate, :ping, :sample_hold, :smooth, :decimate
      note :textures
      see :recipes, :random, :drums
      example 'a bowl struck now and then' do
        seed 3
        bg :try, dust(1.5, range: 0.4..1).resonate(:bowl, 196, spread: 0.6).at(-12.db).until(3.bars)
      end
      example 'drifting detune and cutoff' do
        bg :try, [0, 7, 12].map { |s| 110.hz.transpose(drift(0.3, walk: 0.3).at(-0.12..0.12) + s).saw }.sum.lp4(drift(0.2).at(400..1800)).at(-24.db).until(2.bars)
      end
      example 'vibes that follow the notes' do
        n = seq(A3, E4, A4, C5, E5, A5).n4.loop.notes
        bg :try, n.synth(voices: 3) { |v| v.trigger.resonate(:vibes, v.freq) }.at(-14.db).until(2.bars)
      end
    end

    Help.topic :recipes, 'Recipes: rain, wind, bells, pumps', group: :sound do
      about <<~TEXT
        Short sound recipes to copy and change (`help(:recipes).try(n)`
        plays one).  Rain, wind, vinyl crackle, tape wow, bells, a drone, a
        riser, and a sidechain pump.
      TEXT
      dsl :resonate, :duck, :delay
      commands :dust, :drift, :tween
      note :textures
      see :textures, :dynamics, :effects
      example 'rain' do
        drops = dust(250, range: 0.05..1, seed: 1)
        bg :try, (drops.ping(noise.sample_hold(drops).at(2500..7000), decay: 0.02) * 0.12 + noise.lp4(3000).at(-30.db)).pan(drift(1)).until(2.bars)
      end
      example 'wind' do
        bg :try, (noise.filter(:bandpass, cutoff: drift(0.4, walk: 0.4).at(250..1400), quality: 3) * drift(0.3, range: 0.15..1)).until(2.bars)
      end
      example 'vinyl crackle' do
        crackle = dust(40, bipolar: true).filter(:highpass, cutoff: 1500) * 0.3 + dust(1.5, range: 0.3..1).ping(1200, decay: 0.01) * 0.2
        bg :try, (crackle.at(-6.db) + 220.hz.triangle.at(-24.db)).until(2.bars)
      end
      example 'tape wow and flutter' do
        bg :try, 330.hz.triangle.at(-22.db).delay(drift(0.8, smooth: :cosine).at(0.004..0.007) + 6.hz.lfo.at(-0.0001..0.0001)).until(2.bars)
      end
      example 'bells' do
        n = seq(E5, B4, G5, D5).n2.loop.notes
        bg :try, n.synth(voices: 4) { |v| v.trigger.resonate(:bell, v.freq) }.at(-8.db).until(2.bars)
      end
      example 'a breathing drone' do
        bg :try, 55.hz.unison(5, detune: 0.15) { |p| p.saw }.lp4(drift(0.15, walk: 0.3).at(200..900), resonance: 0.3).at(drift(0.25, range: 0.5..1)).at(-16.db).until(2.bars)
      end
      example 'a noise riser' do
        bg :try, noise.filter(:bandpass, cutoff: tween([300.hz, 6000.hz], 2.bars, loop: false), quality: 2).at(tween([0.03, 0.3], 2.bars, loop: false)).until(2.bars)
      end
      example 'a sidechain pump' do
        kick = grid(4, 'xxxx').loop.trigger.ping(50, decay: 0.3)
        pad = 220.hz.unison(3, detune: 0.1) { |p| p.saw }.lp4(1500).at(-20.db)
        bg :try, (pad.duck(kick) + kick.at(-14.db)).until(2.bars)
      end
    end
  end
end
