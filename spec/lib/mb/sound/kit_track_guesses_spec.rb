require 'spec_helper'
require_relative '../../../support/sf2_writer'

# The console lines of the maintainer's take of 2026-11-21 (ux-friction-4)
# around a drum kit track: an instrument given to bg or swap where a clip
# goes, live MIDI given to swap, the same clip given to bg again, and a
# pitched generator on a kit.  Live mode on the default Session (the
# console's notices print only outside a Session context), a synthetic
# SoundFont as the acoustic kit.
RSpec.describe 'Console lines on a kit track (ux-friction-4)', :aggregate_failures do
  before do
    dir = File.dirname(tmp_path('fonts/x'))
    FileUtils.mkdir_p(dir)
    MB::Sound::Sampler::FontPath.only = [dir]
    SF2Writer.drum_kit(File.join(dir, 'Black_Pearl_4_LV2.sf2'), keys: 35..61, name: 'Black Pearl')
    MB::Sound.live = true
    MB::Sound.use_output(MB::Sound::NullOutput.new(channels: 2, sleep: :virtual))
    expect {
      MB::Sound.track(:drums, MB::Sound.kit(:acoustic))
      MB::Sound.bg(:drums, MB::Sound::L.gen.beat.rock)
    }.to output(//).to_stdout
  end

  after do
    MB::Sound.live = false
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound.rewind
  end

  let(:session) { MB::Sound::Session.default }

  it 'refuses an instrument given to bg or swap on a track, naming track with the instrument written out' do
    font = MB::Sound.sf2('Black_Pearl_4_LV2', preset: [0, 0])
    before = session.players[:drums]
    %w[bg swap].each do |cmd|
      expect { expect(MB::Sound.public_send(cmd, :drums, font)).to be_nil }.to output(
        /#{cmd} :drums, sf2\("Black_Pearl_4_LV2", preset: \[0, 0\]\): that is a drum kit \(an instrument\), not a clip, and :drums is a track: track :drums, sf2\("Black_Pearl_4_LV2", preset: \[0, 0\]\) gives the track that instrument/
      ).to_stderr
    end
    expect(session.players[:drums]).to eq(before)
    # (a player that isn't a track still auditions it)
    expect { MB::Sound.bg(:try, font) }.not_to output.to_stderr
    expect(session.players[:try]).to include('demo phrase')
  end

  it "leads live MIDI given to swap with arm and wire, the stream named as typed" do
    stream = session.midi_in.stream
    expect { MB::Sound.swap(:drums, stream) }.to output(
      /swap :drums: that is live MIDI, not a clip, so it can't be :drums's clip\. To play :drums from your keyboard while its clip plays on: arm :drums \(or wire :drums, midi\); to keep what you play as :drums's clip: arm :drums, then capture :drums \(or rec 4\)/
    ).to_stderr
    expect { MB::Sound.bg(:drums, stream) }.to output(/bg :drums: that is live MIDI.*wire :drums, midi/).to_stderr
  end

  it 'says when bg gives a track the clip it already plays, and once per track when a pitched generator plays a kit' do
    clip = MB::Sound::L.gen.acid_rhythm(seed: 13)
    expect { MB::Sound.swap(:drums, clip) }.to output(
      /\e\[2mswap :drums: L\.gen\.acid_rhythm writes pitches; on :drums's kit each note is a drum \(here [a-z_]+(, [a-z_]+)*\); L\.gen\.beat lists drum beats\e\[0m/
    ).to_stdout
    expect { expect(MB::Sound.bg(:drums, clip)).to be_nil }.to output(
      "\e[2mbg :drums: :drums already plays that clip (or has it queued), so nothing changes\e[0m\n"
    ).to_stdout
    expect { MB::Sound.bg(:drums, MB::Sound::L.gen.acid_rhythm(seed: 14)) }.not_to output(/writes pitches/).to_stdout # (once per track)
    expect { MB::Sound.bg(:drums, MB::Sound::L.gen.beat.funk) }.not_to output(/writes pitches|already plays/).to_stdout
  end
end
