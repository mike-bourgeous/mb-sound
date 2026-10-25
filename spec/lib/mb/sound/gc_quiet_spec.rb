RSpec.describe(MB::Sound::GCQuiet) do
  before { skip 'GC.config is not available' unless MB::Sound::GCQuiet::ENABLED }

  it 'holds off major collections inside the block (nested too) and restores the setting' do
    expect(GC.config[:rgengc_allow_full_mark]).to eq(true)
    MB::Sound::GCQuiet.during do
      expect(GC.config[:rgengc_allow_full_mark]).to eq(false)
      MB::Sound::GCQuiet.during { expect(MB::Sound::GCQuiet.active?).to eq(true) }
      expect(GC.config[:rgengc_allow_full_mark]).to eq(false)
    end
    expect(GC.config[:rgengc_allow_full_mark]).to eq(true)
    expect(MB::Sound::GCQuiet.active?).to eq(false)

    expect { MB::Sound::GCQuiet.during { raise 'oops' } }.to raise_error('oops')
    expect(GC.config[:rgengc_allow_full_mark]).to eq(true)
  end

  it 'leaves a setting someone else turned off alone' do
    GC.config(rgengc_allow_full_mark: false)
    MB::Sound::GCQuiet.during { }
    expect(GC.config[:rgengc_allow_full_mark]).to eq(false)
  ensure
    GC.config(rgengc_allow_full_mark: true)
  end

  it "runs a Session's scheduled blocks inside it" do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_size: 800, realtime: false,
      transport: MB::Sound::Sequence::Transport.new(bpm: 120), raise_errors: true)
    seen = nil
    MB::Sound::Session.with_context(session: s) { MB::Sound.at_bar(1) { seen = GC.config[:rgengc_allow_full_mark] } }
    s.process_buffer
    expect(seen).to eq(false)
    expect(GC.config[:rgengc_allow_full_mark]).to eq(true)
  ensure
    s&.close
  end
end
