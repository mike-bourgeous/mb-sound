require 'spec_helper'
require_relative '../../../../support/sf2_writer'

# SoundFont kits by name and role (drum-gen-1): the font search path,
# drum maps on SoundFont kits, and kit(:acoustic).  Synthetic fonts only;
# the system folders are stubbed out so installed fonts never play here.
RSpec.describe 'SoundFont kits by name and role', :aggregate_failures do
  let(:font_path) { MB::Sound::Sampler::FontPath }
  let(:dir) { File.dirname(tmp_path('fonts/x')) }

  before do
    FileUtils.mkdir_p(dir)
    font_path.only = [dir]
  end

  after do
    MB::Sound::Drums::InstalledKits.reset_notices
  end

  it 'searches $MB_SOUND_SOUNDFONTS, then the system folders, existing ones only; specs search none of them' do
    font_path.only = nil
    stub_const('MB::Sound::Sampler::FontPath::DIRS', [File.join(dir, 'missing'), dir].freeze)
    other = File.dirname(tmp_path('more/x'))
    FileUtils.mkdir_p(other)
    env = ENV['MB_SOUND_SOUNDFONTS']
    begin
      ENV['MB_SOUND_SOUNDFONTS'] = [other, dir].join(File::PATH_SEPARATOR)
      expect(font_path.dirs).to eq([other, dir])
    ensure
      ENV['MB_SOUND_SOUNDFONTS'] = env
    end
    expect(font_path::DIRS).to include(File.join(dir, 'missing'))
    expect(MB::Sound::Sampler::FontPath.const_get(:DIRS, false)).to be_frozen
  end

  it 'lists the system folders: Debian\'s, Homebrew\'s share folders, and macOS\'s Banks folder' do
    expect(font_path::DIRS).to include('/usr/share/sounds/sf2', '/usr/share/soundfonts', '/opt/homebrew/share/soundfonts', '~/Library/Audio/Sounds/Banks')
    font_path.only = []
    expect(font_path.dirs).to eq([])
    expect(MB::Sound::Drums::InstalledKits.found(:acoustic)).to be_nil
  end

  # The level of the first hit of +note+ on +inst+ (a constant per key in
  # SF2Writer.drum_kit fonts; 0 when nothing plays).
  def hit(inst, note, velocity: 0.8)
    clip = MB::Sound.seq(MB::Sound::Note.new(note)).n4.vel(velocity)
    inst.sampler(clip, voices: 2).sample(2400).to_a.max
  end

  it 'finds fonts by name on the search path, keeps the name, and reports missing and ambiguous names' do
    SF2Writer.drum_kit(File.join(dir, 'Spec_Pearl_4_LV2.sf2'), keys: 35..61, name: 'Spec Pearl')
    FileUtils.mkdir_p(File.join(dir, 'gm'))
    SF2Writer.drum_kit(File.join(dir, 'gm', 'Spec_GM.sf2'), keys: 27..87, name: 'Standard', bank: 128)
    expect(font_path.dirs).to eq([dir])
    expect(font_path.names).to eq(%w[Spec_GM Spec_Pearl_4_LV2])
    expect(font_path.find('spec_pearl')).to eq(File.join(dir, 'Spec_Pearl_4_LV2.sf2'))
    expect(font_path.find('Spec_GM.sf2')).to eq(File.join(dir, 'gm', 'Spec_GM.sf2'))
    expect(font_path.find('Nothing')).to be_nil
    expect { font_path.find('Spec') }.to raise_error(font_path::Ambiguous, /Spec_GM, Spec_Pearl_4_LV2/)
    expect { MB::Sound.sf2('Spec_Perl') }.to raise_error(ArgumentError, /no SoundFont named "Spec_Perl".*did you mean "Spec_Pearl_4_LV2"/)

    inst = MB::Sound.sf2('Spec_Pearl', preset: [0, 0])
    expect(inst.lineage).to eq([:sf2, :sf2, ['Spec_Pearl'], { preset: [0, 0] }])
    expect(MB::Sound.sf2('Spec_Pearl').path).to eq('Spec_Pearl')

    # a document names the font, never its path
    g = MB::Sound.sf2('Spec_Pearl', preset: [0, 0]).sampler(MB::Sound.seq(MB::Sound::Note.new(36)).n4, voices: 2)
    text = MB::Sound::GraphIO.dump(g)
    expect(text).to include("sf2(\"Spec_Pearl\"")
    expect(text).not_to include(dir)
    doc = tmp_path('kit.mbg.rb')
    File.write(doc, text)
    back = MB::Sound::GraphIO.load(doc)
    expect(back.to_ruby).to include("sf2(\"Spec_Pearl\"")
    expect { MB::Sound::GraphIO.load(text.sub('"Spec_Pearl"', "\"#{dir}/Spec_Pearl_4_LV2.sf2\""), base_dir: File.dirname(doc)) }
      .to raise_error(MB::Sound::GraphIO::LoadError, /relative to the document/)
  end

  it 'plays drum roles on a kit with the acoustic layout: GM toms on its toms, its own articulations, silence for what it lacks' do
    SF2Writer.drum_kit(File.join(dir, 'Black_Pearl_Spec.sf2'), keys: 35..61, name: 'Black Pearl Spec')
    kit = MB::Sound.sf2('Black_Pearl_Spec', preset: [0, 0])
    raw = MB::Sound.sf2('Black_Pearl_Spec', preset: [0, 0], roles: false)
    expect(kit.drum_map.layout).to eq(:acoustic_kit)
    expect(raw.drum_map).to be_nil
    r = MB::Sound::Drums::Roles
    expect(hit(kit, 36)).to eq(hit(raw, 36))
    expect(hit(kit, r.note(:high_tom))).to eq(hit(raw, 45))      # GM 50: the rack tom, never the crash choke
    expect(hit(kit, r.note(:half_open_hat))).to eq(hit(raw, 46))
    expect(hit(kit, r.note(:hat_swish))).to eq(hit(raw, 48))
    expect(hit(kit, r.note(:crash_choke))).to eq(hit(raw, 50))
    expect(hit(kit, r.note(:ride_shank))).to eq(hit(raw, 59))
    expect(hit(kit, r.note(:high_bongo))).to eq(0)               # no bongos: silent, not the third crash
    expect(hit(raw, 60)).to be > 0
  end

  it 'recognises the layout by key set when the name says nothing, and maps a GM bank by its fallbacks' do
    SF2Writer.drum_kit(File.join(dir, 'Mystery.sf2'), keys: 35..61, name: 'Kit', velocity_layers: 2)
    kit = MB::Sound.sf2('Mystery', preset: [0, 0])
    expect(kit.drum_map&.layout).to eq(:acoustic_kit)
    raw = MB::Sound.sf2('Mystery', preset: [0, 0], roles: false)
    # (both velocity layers move together)
    expect(hit(kit, 50, velocity: 0.3)).to eq(hit(raw, 45, velocity: 0.3))
    expect(hit(kit, 50, velocity: 0.9)).to eq(hit(raw, 45, velocity: 0.9))
    expect(hit(kit, 50, velocity: 0.9)).to be > hit(kit, 50, velocity: 0.3)

    SF2Writer.drum_kit(File.join(dir, 'Spec_GM.sf2'), keys: 27..87, name: 'Standard', bank: 128)
    gm = MB::Sound.sf2('Spec_GM', preset: [128, 0])
    graw = MB::Sound.sf2('Spec_GM', preset: [128, 0], roles: false)
    expect(gm.drum_map.layout).to be_nil
    expect(hit(gm, 50)).to eq(hit(graw, 50))
    expect(hit(gm, MB::Sound::Drums::Roles.note(:half_open_hat))).to eq(hit(graw, 46))
    expect(hit(gm, MB::Sound::Drums::Roles.note(:crash_choke))).to eq(0)

    # a melodic preset (bank 0, wide regions) keeps its keys
    SF2Writer.write(File.join(dir, 'Keys.sf2'), samples: [{ name: 's', data: [0.5] * 2400, rate: 48000, pitch: 60 }],
      instruments: [{ name: 'Keys', zones: [{ key_range: [0, 127], sample_id: 0 }] }], presets: [{ name: 'Keys', program: 0, zones: [{ instrument: 0 }] }])
    expect(MB::Sound.sf2('Keys', preset: 0).drum_map).to be_nil
  end

  it 'plays kit(:acoustic) on the first installed kit of its list, else the TR-909 with one line in the console only' do
    kits = MB::Sound::Drums::InstalledKits
    e = MB::Sound.kit(:acoustic)
    expect(e).to equal(MB::Sound::L.kit.acoustic)
    expect(e.to_ruby).to eq('kit(:acoustic)')
    expect(MB::Sound::L.kit.installed.names).to include(:acoustic, :jazz, :hand_percussion, :gm)
    expect { MB::Sound.kit(:acustic) }.to raise_error(ArgumentError, /No kit :acustic.*:acoustic/m)

    expect(kits.found(:acoustic)).to be_nil
    expect(kits.instrument(:acoustic)).to eq(:tr909)
    clip = MB::Sound.seq(MB::Sound::Note.new(36)).n4
    expect { expect(kits.play(:acoustic, clip)).to be_a(MB::Sound::Drums::Kit) }.not_to output.to_stderr
    expect(kits.message(:acoustic)).to match(/\Akit\(:acoustic\): no acoustic SoundFont installed \(apt install avldrums\.lv2-soundfont.*playing tr909\z/)
    begin
      MB::Sound.live = true
      expect { kits.play(:acoustic, clip) }.to output(/apt install avldrums\.lv2-soundfont/).to_stderr
      expect { kits.play(:acoustic, clip) }.not_to output.to_stderr # (once)
    ensure
      MB::Sound.live = false
    end

    # a GM bank is on the list after the acoustic kits; Red Zeppelin before it
    SF2Writer.drum_kit(File.join(dir, 'TimGM6mb.sf2'), keys: 27..87, name: 'Standard', bank: 128)
    expect(kits.found(:acoustic)).to eq(['TimGM6mb', [128, 0]])
    SF2Writer.drum_kit(File.join(dir, 'Red_Zeppelin_4_LV2.sf2'), keys: 35..61, name: 'Red Zeppelin')
    expect(kits.found(:acoustic)).to eq(['Red_Zeppelin_4_LV2', [0, 0]])
    inst = kits.instrument(:acoustic)
    expect(inst.lineage).to eq([:sf2, :sf2, ['Red_Zeppelin_4_LV2'], { preset: [0, 0] }])
    expect(inst.drum_map.layout).to eq(:acoustic_kit)
    expect { kits.play(:acoustic, clip) }.not_to output.to_stderr
  end

  it 'plays a generator on kit(:acoustic) as a track, saving the kind' do
    SF2Writer.drum_kit(File.join(dir, 'Black_Pearl_4_LV2.sf2'), keys: 35..61, name: 'Black Pearl')
    MB::Sound.rewind
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    begin
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.track(:drums, MB::Sound.kit(:acoustic))
        MB::Sound.scene(:a, drums: MB::Sound::L.gen.beat.techno)
        MB::Sound.go(:a, on: :now)
      }
      60.times { s.process_buffer }
      left = Numo::SFloat.cast(out.captured[0])
      expect(left.abs.max).to be > 0.001
      text = MB::Sound::GraphIO.dump(s.arrangement, name: 'g')
      expect(text).to include('track :drums, drums, :acoustic')
      expect(text).to include('L.gen.beat.techno(seed: 5)')
      expect(text).not_to include(dir)
    ensure
      s.close
      MB::Sound.rewind
    end
  end

  it 'completes installed font names in sf2 quotes without a slash' do
    SF2Writer.drum_kit(File.join(dir, 'Black_Pearl_4_LV2.sf2'), keys: 35..61, name: 'Black Pearl')
    c = MB::Sound::UI::Completion
    expect(c.paths_for('Black', "kit = sf2('Black")).to include('Black_Pearl_4_LV2')
    expect(c.paths_for('black', "sf2 'black")).to include('Black_Pearl_4_LV2')
    expect(c.paths_for('Black', "read 'Black").to_a).not_to include('Black_Pearl_4_LV2')
  end
end
