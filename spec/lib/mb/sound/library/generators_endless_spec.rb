require 'spec_helper'
require_relative '../../../../support/generator_launch'

# Generators have no natural end (beat-halftime-1, 2026-11-22; the
# maintainer: "L.gen.beat.halftime stops after 8 bars"): `latency :video`
# after a `panic` had started a new session without his drums track, and
# `bg :drums, L.gen.beat.halftime` with no track played the 8-bar
# audition (`play entry`'s) and stopped.  The sweep: every L.gen entry, on
# a track and with no track, is still playing and still sending notes well
# past any cycle, hold block, fill period, or audition length, at two
# tempos, plain and steered (note-ons counted, non-realtime Sessions).
RSpec.describe MB::Sound::Library::Generators, 'generators keep playing', :aggregate_failures do
  include GeneratorLaunch

  # (the maintainer's sequence, from his take of 2026-11-21)
  it 'plays a generator entry given to bg with no track without an end, on its instrument, as the track plays it' do
    per, players, s = launch('bg :drums, L.gen.beat.halftime', bpm: 240, bars: 20, buffer: 800)
    expect(players).to eq([:drums])
    expect(per[8..]).to all(be > 0)
    expect(s.players[:drums]).to eq('L.gen.beat.halftime on acoustic')
    ref, = launch('track :drums, L.gen.beat.halftime; bg :drums', bpm: 240, bars: 20, buffer: 800)
    expect(per).to eq(ref)

    per, players, = launch('bg L.gen.beat.funk', bpm: 240, bars: 12, buffer: 800)
    expect(players.length).to eq(1)
    expect(per[8..]).to all(be > 0)

    # play keeps the 8-bar audition (labeled)
    expect(MB::Sound::Library::Audition.playable(MB::Sound::L.gen.beat.halftime).description).to end_with('8 bars')
  end

  it 'says what bg plays on with no track, and names a track a new output left behind' do
    MB::Sound.live = true
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, sleep: :virtual))
    expect {
      MB::Sound.track(:drums, :tr909)
      MB::Sound.latency(:video)
    }.to output(//).to_stdout
    expect(MB::Sound::Session.default.arrangement.tracks).to be_empty
    expect(MB::Sound::Session.left_behind).to eq([:drums])
    expect { MB::Sound.bg(:drums, MB::Sound::L.gen.beat.house) }.to output(
      /bg :drums: L\.gen\.beat\.house on tr909, as a player \(no track :drums: it went with the old session when latency or use_output changed the output\); track :drums, L\.gen\.beat\.house gives it a track and knobs/
    ).to_stdout
    expect(MB::Sound::Session.default.players.keys).to eq([:drums])
    expect { MB::Sound.bg(:other, MB::Sound::L.gen.beat.techno) }.to output("\e[2mbg :other: L.gen.beat.techno on tr909, as a player (no track :other); track :other, L.gen.beat.techno gives it a track and knobs\e[0m\n").to_stdout
    expect { MB::Sound.stop(:all, fade: 0) }.to output(//).to_stdout
    expect { MB::Sound.bg(:drums, MB::Sound::L.gen.beat.house.call.loop) }.to output(/bg :drums: a player, not a track :drums: it went with the old session/).to_stdout
    expect { MB::Sound.stop(:all, fade: 0) }.to output(//).to_stdout
  ensure
    MB::Sound.live = false
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
  end

  it 'takes .loop on a generator entry as the entry (its clip loops already), and names .call.loop for a clip entry' do
    gen = MB::Sound::L.gen.beat.pop
    expect(gen.loop).to equal(gen)
    expect(gen.call.loop.events_for(9)).to eq(gen.call.events_for(9)) # (a generator clip loops already)
    MB::Sound.live = true
    expect { gen.loop }.to output("\e[2mL.gen.beat.pop loops already (a generator has no end)\e[0m\n").to_stdout
    MB::Sound.live = false
    n = 0
    expect(MB::Sound::L.fx.reverb.hall.loop { break 3 if (n += 1) == 3 }).to eq(3) # (Kernel#loop with a block)
    expect { MB::Sound::L.fx.reverb.hall.loop }.to raise_error(NoMethodError, /L\.fx\.(reverb\.)?hall\.loop: .*clips loop/)
  ensure
    MB::Sound.live = false
  end

  # gen-morph-1: a morph of two generators (a clip, on the first side's
  # instrument with no track) keeps playing in both spellings, beats and
  # melodic lines, past bars 9 and 33
  it 'keeps a morph of two generators playing on a track and with no track', render_budget: { seconds: 120, reason: 'two morphs, two spellings, 40 bars at 960 BPM' } do
    { 'L.gen.beat.rock.morph(:funk, morph: 0.5)' => true, 'L.gen.koto_motif.morph(:phrygian_motif, morph: 0.5)' => false }.each do |m, drums|
      { track: "track :x, #{m}; bg :x", no_track: "bg :x, #{m}" }.each do |label, code|
        per, players, = launch(code, bpm: 960, bars: 40)
        what = "#{m} #{label}: #{per.inspect}"
        expect(players).to eq([:x]), what
        [9, 33].each { |b| expect(per[b - 1, 8].sum).to be > 0, "#{what}: silent from bar #{b}" }
        expect(per.min).to be > 0, what if drums
      end
    end
  end

  # The class: no launch spelling gives a generator an end (the melodic
  # entries: generators_endless_melodic_spec.rb; the slow tier's longer
  # runs: generators_endless_slow_spec.rb)
  describe 'the beat family sweep' do
    MB::Sound::L.gen.beat.entries.each do |entry|
      it("keeps #{entry.head_path} playing on a track and with no track") { expect_keeps_playing(entry) }
    end
  end
end
