require_relative '../../../../support/ui_helpers'

# Live paths read no files (ui-perf-1): on the Linux desktop the library
# and the checkout live on sshfs, where each stat is a network round trip
# on the painter thread.  UI::FileWatch sees the Ruby-level calls (File,
# IO, Dir class methods); it can't see calls inside C extensions.
RSpec.describe('live file access') do
  # File calls the painter may make, with reasons: the data-file reload
  # (pane files, themes, layouts; Tiles::RELOAD, once a second, in the
  # user's data directory)
  ALLOWED_PAINTER_FILE_CALLS = [%r{\Alib/mb/sound/ui/pane_files\.rb:}, %r{\Agems/mb-term/lib/mb/term/data_file\.rb:}, %r{\Alib/mb/sound/ui\.rb:}].freeze

  describe MB::Sound::Library::Index do
    it 'gives a live thread the last scan of the documents and rescans in the background when it is stale' do
      index = MB::Sound::Library.index
      first = index.document_entries # (a scan where it runs: not a live thread)
      expect(first).not_to be_empty

      calls = nil
      list = nil
      t = Thread.new do
        Thread.current[:mb_sound_live] = true
        calls = MB::Sound::UI::FileWatch.watch([Thread.current]) { list = index.document_entries }
      end
      t.join
      expect(calls).to eq([])
      expect(list).to equal(index.instance_variable_get(:@document_list))

      # Stale: the live thread still gets the list at once, and a rescan runs elsewhere
      index.instance_variable_set(:@document_list_at, -1e9)
      t = Thread.new do
        Thread.current[:mb_sound_live] = true
        calls = MB::Sound::UI::FileWatch.watch([Thread.current]) { list = index.document_entries }
      end
      t.join
      expect(calls).to eq([])
      wait_until { !index.document_scan? }
      expect(index.instance_variable_get(:@document_list_at)).to be > 0
      expect(index.document_entries.map(&:name)).to eq(first.map(&:name))
    end
  end

  describe 'the tiled screen' do
    after { @tiles&.stop; @term&.close }

    it "draws the library picker for a while with no file calls on the painter beyond the data-file reload" do
      @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120)
      @term.wait_for('t> ')
      @tiles.show(:picker)
      wait_until { @tiles.listed_panes.include?(:picker) rescue @tiles.tiler.layout.panes.include?(:picker) }
      wait_until { @tiles.rates.measured[:picker].to_f > 0 }
      calls = MB::Sound::UI::FileWatch.watch([@tiles.thread]) { sleep 2.5 }
      other = calls.reject { |_, _, loc, _| ALLOWED_PAINTER_FILE_CALLS.any? { |re| loc.to_s.match?(re) } }
      expect(other).to eq([]), other.first(10).map(&:inspect).join("\n")
    end
  end
end
