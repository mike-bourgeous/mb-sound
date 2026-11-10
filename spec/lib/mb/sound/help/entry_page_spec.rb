require 'mb/sound/help'

# `help L.inst.x` (Help::EntryPage): a library entry's description,
# settings, and lines that use it, which run as shown.
RSpec.describe MB::Sound::Help::EntryPage do
  def new_session
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
  end

  %i[instrument effect generator kit flow].each do |kind|
    it "shows a #{kind}'s description and settings, and its lines run" do
      entry = MB::Sound::Library.index.entries(kind: kind).find { |e| e.shelf.shipped? && !e.name.to_s.start_with?('sq80') }
      page = MB::U.remove_ansi(MB::Sound.help(entry).to_s)
      expect(page).to include(entry.head_path)
      expect(page.gsub(/\s+/, ' ')).to include(entry.about.gsub(/\s+/, ' ').delete('`')) if entry.about
      (entry.params rescue {}).to_h.each_key { |k| expect(page).to include(k.to_s) }

      code = page.lines.drop_while { |l| l.strip != 'Use it' }.drop(1).take_while { |l| !l.strip.empty? }.map { |l| l.sub(/\s+# .*/, '').strip }
      expect(code).not_to be_empty if %i[instrument effect generator kit].include?(kind)
      session = new_session
      MB::Sound::Session.with_context(session: session) do
        console = MB::Sound.module_eval('binding')
        # (a flow needs scenes named like its sections: shown, not run)
        (kind == :flow ? [] : code).each do |line|
          console.eval(line)
          8.times { session.process_buffer(800) }
        end
      end
    ensure
      session&.close
    end
  end
end
