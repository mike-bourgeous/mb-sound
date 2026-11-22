require 'spec_helper'

# Drum roles and kit maps (drum-gen-1): generators write roles, each kit
# maps them to its keys, one fallback chain for roles a kit lacks.
RSpec.describe MB::Sound::Drums::Roles, :aggregate_failures do
  let(:roles) { MB::Sound::Drums::Roles }
  let(:grid) { MB::Sound::Sequence::Grid }

  it 'names the acoustic roles beyond GM on keys of their own that grids and beats take' do
    expect(roles.note(:half_open_hat)).to eq(100)
    expect(roles.note(:hat)).to eq(42)
    gm = grid::GM_DRUMS.values.uniq
    expect(grid::EXTENDED_DRUMS.values & gm).to eq([])
    expect(grid::EXTENDED_DRUMS.values).to all(be > 87)
    expect(grid.row_value(:ride_shank)).to eq(102)
    clip = MB::Sound.beats(4, seed: 1) { half_open_hat [1, 0, 1, 0], keep: [0, 2] }
    expect(clip.events_for(0).map { |e| MB::Sound::Note.new(e.value).number.round }.uniq).to eq([100])
  end

  it 'falls back along one chain (half-open hat, open, closed; high tom, mid, low; ride bell, ride)' do
    expect(roles.chain(:half_open_hat)).to eq(%i[open_hat closed_hat])
    expect(roles.chain(:high_tom)).to start_with(:high_mid_tom, :mid_tom, :low_tom)
    expect(roles.chain(:ride_bell)).to eq(%i[ride])
    expect(roles.chain(:crash_choke)).to eq([])
    # every role named in the table is a role, and no chain loops forever
    expect(roles::FALLBACK.to_a.flatten.uniq - roles::NOTES.keys).to eq([])
    roles::NOTES.each_key { |r| expect(roles.chain(r)).not_to include(r) }
  end

  it 'maps a GM kit: GM roles on their own keys, the acoustic roles to their fallbacks, chokes silent nowhere' do
    m = roles.map(keys: 27..87)
    expect(m.key(:high_tom)).to eq(50)
    expect(m.key(:half_open_hat)).to eq(46)
    expect(m.key(:ride_shank)).to eq(51)
    expect(m.key(:crash3)).to eq(57)
    expect(m.remap.keys).to all(be > 87) # (GM keys play as written)
    expect(m.missing).to include(:crash_choke)
  end

  it 'maps the acoustic SoundFont layout by name or key set: its toms for GM toms, never the swish or choke keys' do
    expect(roles.layout_for(name: 'Black_Pearl_4_LV2')).to eq(:acoustic_kit)
    expect(roles.layout_for(name: 'Red Zeppelin')).to eq(:acoustic_kit)
    expect(roles.layout_for(name: 'Buskmans_Holiday_LV2')).to eq(:hand_percussion)
    expect(roles.layout_for(keys: 35..61)).to eq(:acoustic_kit)
    expect(roles.layout_for(keys: 27..87)).to be_nil
    m = roles.map(keys: 35..61, layout: :acoustic_kit)
    expect(m.key(:high_tom)).to eq(45)
    expect(m.key(:high_mid_tom)).to eq(47)
    expect(m.key(:hat_swish)).to eq(48)
    expect(m.key(:crash_choke)).to eq(50)
    expect(m.remap[50]).to eq(45) # (GM's high tom key: the rack tom, not the crash choke)
    expect(m.remap[48]).to eq(47)
    expect(m.remap[100]).to eq(46)
    expect(m.remap[104]).to eq(50)
    expect(m.remap.fetch(60)).to be_nil # (GM's high bongo: silent, not the third crash)
    expect(m.missing).to include(:high_bongo)
  end

  it 'adds the acoustic roles to the drum machines through the fallbacks' do
    gm = MB::Sound::Drums::TR909::GM_MAP
    expect(gm[:open_hat]).to include(46, 100)
    expect(gm[:ride]).to include(51, 102)
    expect(gm.values.flatten).not_to include(104, 105, 106) # (chokes have no fallback)
    expect(MB::Sound::Drums::TR808::GM_MAP[:cymbal]).to include(103)
  end
end
